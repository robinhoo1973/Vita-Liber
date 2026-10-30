import Foundation

/// 损坏数据库修复界面文案（业主 2026-10-30 单独接口四动作）。
extension L10n {
    static var recoveryTitle: String { t("recovery.title") }
    static var recoveryIntro: String { t("recovery.intro") }
    static var recoveryOpen: String { t("recovery.open") }
    static var recoveryClose: String { t("recovery.close") }
    static var recoveryBusy: String { t("recovery.busy") }
    static func recoveryError(_ detail: String) -> String {
        t("recovery.errorFmt").replacingOccurrences(of: "%@", with: detail)
    }

    static var recoveryExportTitle: String { t("recovery.export.title") }
    static var recoveryExportSubtitle: String { t("recovery.export.subtitle") }
    static var recoveryExportPrivacy: String { t("recovery.export.privacy") }
    static var recoveryExportBusy: String { t("recovery.export.busy") }
    static func recoveryExportDone(_ name: String) -> String {
        t("recovery.export.doneFmt").replacingOccurrences(of: "%@", with: name)
    }

    static var recoveryImportTitle: String { t("recovery.import.title") }
    static var recoveryImportSubtitle: String { t("recovery.import.subtitle") }
    static var recoveryImportConfirmTitle: String { t("recovery.import.confirmTitle") }
    static var recoveryImportConfirmBody: String { t("recovery.import.confirmBody") }
    static var recoveryImportAction: String { t("recovery.import.action") }
    static func recoveryImportReport(_ version: Int64) -> String {
        t("recovery.import.reportFmt").replacingOccurrences(of: "%lld", with: "\(version)")
    }

    static var recoveryBackupTitle: String { t("recovery.backup.title") }
    static var recoveryBackupSubtitle: String { t("recovery.backup.subtitle") }
    static var recoveryBackupConfirmTitle: String { t("recovery.backup.confirmTitle") }
    static var recoveryBackupConfirmBody: String { t("recovery.backup.confirmBody") }
    static var recoveryBackupAction: String { t("recovery.backup.action") }
    static func recoveryBackupSummary(_ exportedAt: String, _ records: Int64) -> String {
        t("recovery.backup.summaryFmt")
            .replacingOccurrences(of: "%@", with: exportedAt)
            .replacingOccurrences(of: "%lld", with: "\(records)")
    }

    static var recoveryDeleteTitle: String { t("recovery.delete.title") }
    static var recoveryDeleteSubtitle: String { t("recovery.delete.subtitle") }
    static var recoveryDeleteConfirmTitle: String { t("recovery.delete.confirmTitle") }
    static var recoveryDeleteConfirmBody: String { t("recovery.delete.confirmBody") }
    static var recoveryDeleteAction: String { t("recovery.delete.action") }
    static var recoveryCancel: String { t("recovery.cancel") }

    static var recoveryValidationNotSQLite: String { t("recovery.validation.notSQLite") }
    static var recoveryValidationUnreadable: String { t("recovery.validation.unreadable") }
    static var recoveryValidationIntegrity: String { t("recovery.validation.integrity") }
    static func recoveryValidationTooNew(_ found: Int64, _ supported: Int64) -> String {
        t("recovery.validation.tooNewFmt")
            .replacingOccurrences(of: "%1$lld", with: "\(found)")
            .replacingOccurrences(of: "%2$lld", with: "\(supported)")
    }
    static func recoveryValidationVersion(_ version: Int64) -> String {
        t("recovery.validation.versionFmt").replacingOccurrences(of: "%lld", with: "\(version)")
    }
    static func recoveryValidationMissingTables(_ names: String) -> String {
        t("recovery.validation.missingTablesFmt").replacingOccurrences(of: "%@", with: names)
    }
    static var recoveryValidationArchive: String { t("recovery.validation.archive") }
    static var recoveryValidationIO: String { t("recovery.validation.io") }
    static var recoveryValidationArchiveMultiple: String { t("recovery.validation.archiveMultiple") }
    static var recoveryValidationArchiveSidecars: String { t("recovery.validation.archiveSidecars") }
    static var recoveryBackupTooLarge: String { t("recovery.backup.tooLarge") }
    static var recoveryMigrationKeepHint: String { t("recovery.migrationKeepHint") }
    static var recoveryBackupChecksum: String { t("recovery.backup.checksum") }
    static var recoveryBackupFormat: String { t("recovery.backup.format") }
    static var recoveryBackupConflict: String { t("recovery.backup.conflict") }
}
