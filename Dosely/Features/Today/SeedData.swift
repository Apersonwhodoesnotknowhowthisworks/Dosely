#if DEBUG
import Foundation

enum SeedData {
    static func seedIfEmpty(using repository: MedicationRepository) async {
        let existing = await repository.fetchAllMedications()
        guard existing.isEmpty else { return }

        _ = await repository.saveMedication(
            name: "Metformin",
            dose: "500mg",
            pillsPerDose: 1,
            foodRule: "with",
            notes: "Take with a full glass of water. Helps control blood sugar.",
            currentSupply: 60,
            pillPhotoData: nil,
            schedules: [
                ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127),
                ScheduleInput(timeOfDay: "20:00", daysOfWeek: 127)
            ]
        )

        _ = await repository.saveMedication(
            name: "Lisinopril",
            dose: "10mg",
            pillsPerDose: 1,
            foodRule: "either",
            notes: "For blood pressure. Same time each morning.",
            currentSupply: 30,
            pillPhotoData: nil,
            schedules: [
                ScheduleInput(timeOfDay: "08:00", daysOfWeek: 127)
            ]
        )
    }
}
#endif
