import AppKit
import MarkUpCore

/// Main-thread command history for a reader. Inverse commands are registered synchronously
/// inside UndoManager callbacks; durable commands run in their original order and epoch.
/// Pending local commands overlay store snapshots so cross-window notifications never flash
/// an intermediate save over a newer local undo. A failed save reloads durable state and
/// invalidates this history's commands instead of pretending the optimistic state was saved.
@MainActor
final class AnnotationHistory {
  enum Change: Sendable {
    case insert(TextAnnotation)
    case remove(TextAnnotation)

    var inverse: Change {
      switch self {
      case .insert(let mark): .remove(mark)
      case .remove(let mark): .insert(mark)
      }
    }
  }

  private struct Context: Equatable {
    let documentID: UUID
    let epoch: UInt64
  }

  private struct Pending {
    let id: UUID
    let context: Context
    let change: Change
  }

  weak var undoManager: UndoManager? {
    didSet { undoManager?.levelsOfUndo = 100 }
  }
  private(set) var annotations: [TextAnnotation] = []
  private(set) var revision = 0
  private var committed: [TextAnnotation] = []
  private var context: Context?
  private var highestEpoch: UInt64 = 0
  private var pending: [Pending] = []
  private var tail: Task<Void, Never>?
  private let persist: (Change, UInt64) async throws -> Void
  private let snapshot: (UUID) async -> AnnotationSnapshot?
  private let changed: ([TextAnnotation], UInt64) -> Void
  private let failed: () -> Void
  private let actionName: String

  init(
    actionName: String, persist: @escaping (Change, UInt64) async throws -> Void,
    snapshot: @escaping (UUID) async -> AnnotationSnapshot?,
    changed: @escaping ([TextAnnotation], UInt64) -> Void, failed: @escaping () -> Void
  ) {
    self.actionName = actionName
    self.persist = persist
    self.snapshot = snapshot
    self.changed = changed
    self.failed = failed
  }

  func synchronize(
    documentID: UUID?, annotations: [TextAnnotation], epoch: UInt64, expectedRevision: Int? = nil
  ) {
    guard epoch >= highestEpoch else {
      publish()
      return
    }
    highestEpoch = epoch
    let next = documentID.map { Context(documentID: $0, epoch: epoch) }
    if context == next, let expectedRevision, expectedRevision != revision {
      publish()
      return
    }
    revision += 1
    if context != next { undoManager?.removeAllActions(withTarget: self) }
    // Epoch is global. Commands issued before Clear All must not be submitted afterward.
    pending.removeAll { $0.context.epoch != epoch }
    context = next
    committed = annotations
    publish()
  }

  func insert(anchor: TextAnchor, style: AnnotationStyle) {
    guard let context else { return }
    perform(
      .insert(TextAnnotation(documentID: context.documentID, anchor: anchor, style: style)),
      in: context)
  }

  func remove(_ mark: TextAnnotation) {
    guard let context else { return }
    perform(.remove(mark), in: context)
  }

  /// Detach UI immediately while already accepted saves drain. Dropping an open window must
  /// not discard a just-created mark. Captured epochs still reject concurrent global clears.
  func close() {
    revision += 1
    undoManager?.removeAllActions(withTarget: self)
    undoManager = nil
    context = nil
    committed = []
    annotations = []
  }

  func waitForPendingOperations() async { await tail?.value }

  private func perform(_ change: Change, in commandContext: Context) {
    guard context == commandContext else { return }
    guard pending.count < 128 else {
      failed()
      return
    }
    switch change {
    case .insert(let mark):
      guard mark.documentID == commandContext.documentID,
        !annotations.contains(where: { $0.id == mark.id })
      else { return }
    case .remove(let mark):
      guard mark.documentID == commandContext.documentID,
        annotations.contains(where: { $0.id == mark.id })
      else { return }
    }
    // This must happen before an async boundary, while isUndoing/isRedoing is still true.
    if let manager = undoManager {
      let needsGroup = manager.groupingLevel == 0
      if needsGroup { manager.beginUndoGrouping() }
      manager.registerUndo(withTarget: self) { history in
        MainActor.assumeIsolated { history.perform(change.inverse, in: commandContext) }
      }
      manager.setActionName(actionName)
      if needsGroup { manager.endUndoGrouping() }
    }
    let command = Pending(id: UUID(), context: commandContext, change: change)
    revision += 1
    pending.append(command)
    publish()
    let previous = tail
    // Retain this small adapter until accepted saves finish, even if the window/session
    // disappears before this task first runs. The task releases its captures on completion.
    tail = Task { [self] in
      await previous?.value
      guard pending.contains(where: { $0.id == command.id }) else { return }
      do {
        try await persist(command.change, command.context.epoch)
        pending.removeAll { $0.id == command.id }
        revision += 1
        if context == command.context {
          apply(command.change, to: &committed)
          publish()
        }
      } catch {
        pending.removeAll { $0.context == command.context }
        revision += 1
        guard context == command.context else { return }
        undoManager?.removeAllActions(withTarget: self)
        publish()
        let recoveryRevision = revision
        let latest = await snapshot(command.context.documentID)
        guard context == command.context else { return }
        if let latest {
          synchronize(
            documentID: command.context.documentID, annotations: latest.annotations,
            epoch: latest.epoch, expectedRevision: recoveryRevision)
          if latest.epoch > command.context.epoch { return }
        } else {
          // Keep the last confirmed durable snapshot if recovery itself is unavailable.
          publish()
        }
        failed()
      }
    }
  }

  private func publish() {
    guard let context else { return }
    var optimistic = committed
    for operation in pending where operation.context == context {
      apply(operation.change, to: &optimistic)
    }
    annotations = optimistic
    changed(optimistic, context.epoch)
  }

  private func apply(_ change: Change, to marks: inout [TextAnnotation]) {
    switch change {
    case .insert(let mark):
      if !marks.contains(where: { $0.id == mark.id }) { marks.append(mark) }
    case .remove(let mark): marks.removeAll { $0.id == mark.id }
    }
  }
}
