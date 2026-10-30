import AppKit
import Foundation
import MarkUpCore
import Testing

@testable import MarkUp

@MainActor
struct AnnotationHistoryTests {
  @Test func nativeUndoRedoRegistersSynchronouslyAcrossRepeatedCycles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    fixture.history.insert(anchor: try anchor(), style: .highlightBlue)
    #expect(fixture.history.annotations.count == 1)
    await fixture.history.waitForPendingOperations()
    for _ in 0..<3 {
      fixture.manager.undo()
      #expect(fixture.manager.canRedo)
      #expect(fixture.history.annotations.isEmpty)
      await fixture.history.waitForPendingOperations()
      #expect(await fixture.store.count == 0)
      fixture.manager.redo()
      #expect(fixture.manager.canUndo)
      #expect(fixture.history.annotations.count == 1)
      await fixture.history.waitForPendingOperations()
      #expect(await fixture.store.count == 1)
    }
    let mark = try #require(fixture.history.annotations.first)
    fixture.history.remove(mark)
    await fixture.history.waitForPendingOperations()
    #expect(await fixture.store.count == 0)
    fixture.manager.undo()
    #expect(fixture.manager.canRedo)
    await fixture.history.waitForPendingOperations()
    #expect(await fixture.store.snapshot(documentID: fixture.id).annotations == [mark])
    fixture.manager.redo()
    await fixture.history.waitForPendingOperations()
    #expect(await fixture.store.count == 0)
  }

  @Test func pendingUndoRedoOverlayStoreNotificationsAndPersistInOrder() async throws {
    let gate = SaveGate()
    let fixture = try await Fixture(gate: gate)
    defer { fixture.cleanup() }
    fixture.history.insert(anchor: try anchor(), style: .underline)
    await gate.waitUntilBlocked()
    fixture.manager.undo()
    fixture.manager.redo()
    let optimistic = fixture.history.annotations
    let durable = await fixture.store.snapshot(documentID: fixture.id)
    #expect(durable.annotations.isEmpty)
    fixture.history.synchronize(
      documentID: fixture.id, annotations: durable.annotations, epoch: durable.epoch)
    #expect(fixture.history.annotations == optimistic)
    await gate.release()
    await fixture.history.waitForPendingOperations()
    #expect(await fixture.store.snapshot(documentID: fixture.id).annotations == optimistic)
    #expect(await gate.savedChanges == ["insert", "remove", "insert"])
  }

  @Test func clearWhileSaveIsPendingRejectsEveryOldEpochCommand() async throws {
    let gate = SaveGate()
    let fixture = try await Fixture(gate: gate)
    defer { fixture.cleanup() }
    fixture.history.insert(anchor: try anchor(), style: .highlightYellow)
    await gate.waitUntilBlocked()
    fixture.manager.undo()
    fixture.manager.redo()
    let obsoleteMarks = fixture.history.annotations
    let newEpoch = try await fixture.store.clearAll()
    fixture.history.synchronize(documentID: fixture.id, annotations: [], epoch: newEpoch)
    fixture.history.synchronize(documentID: fixture.id, annotations: obsoleteMarks, epoch: 0)
    #expect(fixture.history.annotations.isEmpty)
    #expect(!fixture.manager.canUndo && !fixture.manager.canRedo)
    await gate.release()
    await fixture.history.waitForPendingOperations()
    #expect(fixture.history.annotations.isEmpty)
    #expect(await fixture.store.count == 0)
    let restarted = try AnnotationStore(directory: fixture.directory)
    #expect(await restarted.count == 0)
    #expect(await restarted.snapshot(documentID: fixture.id).epoch == newEpoch)
    #expect(fixture.probe.failures == 0)
  }

  @Test func failedSaveRollsBackOptimisticChangesAndInvalidatesDependentHistory() async throws {
    let gate = SaveGate(failFirst: true)
    let fixture = try await Fixture(gate: gate)
    defer { fixture.cleanup() }
    fixture.history.insert(anchor: try anchor(), style: .highlightGreen)
    await gate.waitUntilBlocked()
    fixture.manager.undo()
    fixture.manager.redo()
    #expect(fixture.history.annotations.count == 1)
    await gate.release()
    await fixture.history.waitForPendingOperations()
    #expect(fixture.history.annotations.isEmpty)
    #expect(await fixture.store.count == 0)
    #expect(!fixture.manager.canUndo && !fixture.manager.canRedo)
    #expect(fixture.probe.failures == 1)
    // A failure does not permanently disable new valid commands.
    fixture.history.insert(anchor: try anchor(), style: .underline)
    await fixture.history.waitForPendingOperations()
    #expect(await fixture.store.count == 1)
  }

  @Test func closeDetachesUIWhileAnAcceptedSaveFinishes() async throws {
    let gate = SaveGate()
    let fixture = try await Fixture(gate: gate)
    defer { fixture.cleanup() }
    fixture.history.insert(anchor: try anchor(), style: .underline)
    await gate.waitUntilBlocked()
    fixture.history.close()
    let notifications = fixture.probe.notifications
    await gate.release()
    await fixture.history.waitForPendingOperations()
    #expect(await fixture.store.count == 1)
    #expect(fixture.probe.notifications == notifications)
    #expect(!fixture.manager.canUndo && !fixture.manager.canRedo)
  }

  @Test func snapshotStartedBeforeALocalCommandCannotOverwriteItsSuccessfulSave() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let oldSnapshot = await fixture.store.snapshot(documentID: fixture.id)
    let oldRevision = fixture.history.revision
    fixture.history.insert(anchor: try anchor(), style: .underline)
    await fixture.history.waitForPendingOperations()
    let saved = fixture.history.annotations
    fixture.history.synchronize(
      documentID: fixture.id, annotations: oldSnapshot.annotations,
      epoch: oldSnapshot.epoch, expectedRevision: oldRevision)
    #expect(fixture.history.annotations == saved)
    #expect(await fixture.store.snapshot(documentID: fixture.id).annotations == saved)
  }

  @Test func droppingTheWindowBeforeTheSaveTaskStartsDoesNotLoseTheMark() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MarkUp-History-Lifetime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AnnotationStore(directory: directory)
    let id = try await store.documentID(
      for: AnnotationDocumentIdentity(
        resourceIdentifier: "lifetime-file",
        canonicalURL: directory.appendingPathComponent("document.md")))
    var history: AnnotationHistory? = AnnotationHistory(
      actionName: "Annotations",
      persist: { change, epoch in
        switch change {
        case .insert(let mark): try await store.restore(mark, expectedEpoch: epoch)
        case .remove(let mark): _ = try await store.remove(id: mark.id, expectedEpoch: epoch)
        }
      }, snapshot: { id in await store.snapshot(documentID: id) }, changed: { _, _ in },
      failed: { Issue.record("Accepted save failed") })
    history?.synchronize(documentID: id, annotations: [], epoch: 0)
    history?.insert(anchor: try anchor(), style: .underline)
    history?.close()
    let survivingHistory = WeakHistory(history)
    history = nil  // No suspension has allowed the save task to begin yet.
    let deadline = ContinuousClock.now + .seconds(3)
    while await store.count == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await store.count == 1)
    for _ in 0..<100 where survivingHistory.value != nil { await Task.yield() }
    #expect(survivingHistory.value == nil)
  }

  @Test func delayedFailureRecoveryCannotOverwriteNewCommandsOrANewerSnapshot() async throws {
    let saveGate = SaveGate(failFirst: true)
    let recoveryGate = SaveGate()
    let fixture = try await Fixture(gate: saveGate, recoveryGate: recoveryGate)
    defer { fixture.cleanup() }
    fixture.history.insert(anchor: try anchor(), style: .highlightYellow)
    await saveGate.waitUntilBlocked()
    await saveGate.release()
    await recoveryGate.waitUntilBlocked()
    #expect(fixture.history.annotations.isEmpty)
    fixture.history.insert(anchor: try anchor(), style: .underline)
    let external = try await fixture.store.add(
      documentID: fixture.id, anchor: anchor(),
      style: .highlightBlue, expectedEpoch: 0)
    let latest = await fixture.store.snapshot(documentID: fixture.id)
    fixture.history.synchronize(
      documentID: fixture.id, annotations: latest.annotations, epoch: latest.epoch)
    #expect(fixture.history.annotations.count == 2)
    await recoveryGate.release()
    await fixture.history.waitForPendingOperations()
    #expect(fixture.history.annotations.count == 2)
    #expect(fixture.history.annotations.contains(external))
    #expect(await fixture.store.count == 2)
    #expect(fixture.manager.canUndo)
    #expect(fixture.probe.failures == 1)
  }

  private func anchor() throws -> TextAnchor {
    try TextAnchor.capture(
      in: "A distinctive context. Selected text. Trailing context.",
      range: NSRange(location: 23, length: 13))
  }

  @MainActor private final class Probe {
    var notifications = 0
    var failures = 0
  }

  @MainActor private final class WeakHistory {
    weak var value: AnnotationHistory?
    init(_ value: AnnotationHistory?) { self.value = value }
  }

  @MainActor private struct Fixture {
    let directory: URL
    let store: AnnotationStore
    let id: UUID
    let manager = UndoManager()
    let history: AnnotationHistory
    let probe = Probe()

    init(gate: SaveGate? = nil, recoveryGate: SaveGate? = nil) async throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MarkUp-History-\(UUID().uuidString)")
      store = try AnnotationStore(directory: directory)
      id = try await store.documentID(
        for: AnnotationDocumentIdentity(
          resourceIdentifier: "volume:file:birth",
          canonicalURL: directory.appendingPathComponent("document.md")))
      let store = store
      let probe = probe
      history = AnnotationHistory(
        actionName: "Annotations",
        persist: { change, epoch in
          try await gate?.beforeSave()
          switch change {
          case .insert(let mark): try await store.restore(mark, expectedEpoch: epoch)
          case .remove(let mark): _ = try await store.remove(id: mark.id, expectedEpoch: epoch)
          }
          await gate?.record(change)
        },
        snapshot: { id in
          let snapshot = await store.snapshot(documentID: id)
          try? await recoveryGate?.beforeSave()
          return snapshot
        },
        changed: { _, _ in
          probe.notifications += 1
        }, failed: { probe.failures += 1 })
      manager.groupsByEvent = false
      history.undoManager = manager
      history.synchronize(documentID: id, annotations: [], epoch: 0)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
  }
}

private actor SaveGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var blocked = false
  private var first = true
  private let failFirst: Bool
  private(set) var savedChanges: [String] = []

  init(failFirst: Bool = false) { self.failFirst = failFirst }

  func beforeSave() async throws {
    guard first else { return }
    first = false
    blocked = true
    await withCheckedContinuation { continuation = $0 }
    if failFirst { throw AnnotationError.corruptStorage }
  }

  func waitUntilBlocked() async {
    while !blocked { await Task.yield() }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }

  func record(_ change: AnnotationHistory.Change) {
    switch change {
    case .insert: savedChanges.append("insert")
    case .remove: savedChanges.append("remove")
    }
  }
}
