// Read numeric kernel memory accounting for a local test process; no task-port or document access.
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end = NULL;
    long pid = strtol(argv[1], &end, 10);
    if (!end || *end || pid <= 0 || pid > 2147483647) return 2;
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage((int)pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        perror("proc_pid_rusage");
        return 1;
    }
    printf("{\"physical_footprint_bytes\":%llu,\"peak_physical_footprint_bytes\":%llu,\"resident_bytes\":%llu}\n",
           (unsigned long long)usage.ri_phys_footprint,
           (unsigned long long)usage.ri_lifetime_max_phys_footprint,
           (unsigned long long)usage.ri_resident_size);
    return 0;
}
