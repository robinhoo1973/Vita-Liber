import Foundation
import Domain
import Protocols

public struct AppDependencies: Sendable {
    public let db: any DatabaseProtocol
    public let cardService: any CardServiceProtocol
}

public enum AppContainer {

    public static func makeProduction(dbPath: String) throws -> AppDependencies {
        let rawDB = try DatabaseFactory.makeFile(path: dbPath)
        let db = RetryingDatabase(inner: rawDB, maxRetries: 3)

        let migrator = MigrationManager(db: db)
        try migrator.migrateIfNeeded()

        let patientRepo     = PatientRepository(db: db)
        let encounterRepo   = EncounterRepository(db: db)
        let reportRepo      = ClinicalReportRepository(db: db)
        let medScheduleRepo = MedicationScheduleRepository(db: db)
        let appointmentRepo = AppointmentRepository(db: db)

        let engine = StubTextUnderstanding()

        let cardService = CardService(
            patientRepo: patientRepo,
            encounterRepo: encounterRepo,
            reportRepo: reportRepo,
            medScheduleRepo: medScheduleRepo,
            appointmentRepo: appointmentRepo,
            engine: engine
        )

        return AppDependencies(db: db, cardService: cardService)
    }

    public static func makeTest() throws -> AppDependencies {
        let db = try DatabaseFactory.makeInMemory()

        let migrator = MigrationManager(db: db)
        try migrator.migrateIfNeeded()

        let patientRepo     = PatientRepository(db: db)
        let encounterRepo   = EncounterRepository(db: db)
        let reportRepo      = ClinicalReportRepository(db: db)
        let medScheduleRepo = MedicationScheduleRepository(db: db)
        let appointmentRepo = AppointmentRepository(db: db)

        let engine = StubTextUnderstanding()

        let cardService = CardService(
            patientRepo: patientRepo,
            encounterRepo: encounterRepo,
            reportRepo: reportRepo,
            medScheduleRepo: medScheduleRepo,
            appointmentRepo: appointmentRepo,
            engine: engine
        )

        return AppDependencies(db: db, cardService: cardService)
    }
}
