import Foundation

func runStorageMaintenanceTests() {
    section("Storage Maintenance · Migration gating")

    let currentMigrationVersion = 1

    func shouldRunStartupMaintenance(storedVersion: Int, currentVersion: Int = currentMigrationVersion) -> Bool {
        storedVersion < currentVersion
    }

    expect("startup maintenance runs when no migration has been recorded", shouldRunStartupMaintenance(storedVersion: 0))
    expect("startup maintenance skips once the current migration version is recorded", !shouldRunStartupMaintenance(storedVersion: currentMigrationVersion))
    expect("startup maintenance skips newer stored migration versions", !shouldRunStartupMaintenance(storedVersion: currentMigrationVersion + 1))

    section("Storage Maintenance · Byte counting")

    func storageSizeBytes(dataCount: Int?) -> Int64 {
        Int64(dataCount ?? 0)
    }

    expectEqual("missing defaults data reports zero bytes", storageSizeBytes(dataCount: nil), 0)
    expectEqual("present defaults data reports exact byte count", storageSizeBytes(dataCount: 512), 512)
}
