import Foundation
import HealthKit

// MARK: - HealthKitManager

/// Manages HealthKit authorization and sample queries.
/// All HealthKit types are enumerated at runtime — no hardcoded list.
final class HealthKitManager {

    static let shared = HealthKitManager()
    let store = HKHealthStore()

    private init() {}

    enum DataScope: String, CaseIterable, Identifiable {
        case essentials
        case complete

        static let storageKey = "hkb.healthDataScope"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .essentials: return "Core activity, sleep & recovery"
            case .complete: return "All supported Health data"
            }
        }

        var detail: String {
            switch self {
            case .essentials:
                return "Steps, activity, workouts, sleep, heart rate, resting heart rate, and HRV."
            case .complete:
                return "Also includes sensitive categories such as reproductive health, symptoms, nutrition, and clinical-style measurements."
            }
        }
    }

    // MARK: - Type enumeration

    /// Builds the complete set of all readable HKSampleTypes at runtime.
    /// Includes all quantity types, category types, and workout type.
    static func allSampleTypes() -> Set<HKSampleType> {
        var types = Set<HKSampleType>()

        // --- Quantity types ---
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            // Activity
            .stepCount, .distanceWalkingRunning, .distanceCycling,
            .distanceSwimming, .distanceDownhillSnowSports, .distanceWheelchair,
            .pushCount, .flightsClimbed, .nikeFuel, .activeEnergyBurned,
            .basalEnergyBurned, .swimmingStrokeCount, .appleExerciseTime,
            .appleMoveTime, .appleStandTime, .appleWalkingSteadiness,
            // Body measurements
            .bodyMassIndex, .bodyFatPercentage, .height, .bodyMass,
            .leanBodyMass, .waistCircumference,
            // Fitness
            .vo2Max,
            // Vitals
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
            .walkingHeartRateAverage, .oxygenSaturation, .bodyTemperature,
            .bloodPressureSystolic, .bloodPressureDiastolic, .respiratoryRate,
            .peripheralPerfusionIndex,
            // Results
            .bloodGlucose, .electrodermalActivity, .forcedExpiratoryVolume1,
            .forcedVitalCapacity, .peakExpiratoryFlowRate, .inhalerUsage,
            .insulinDelivery, .bloodAlcoholContent, .numberOfTimesFallen,
            .uvExposure, .atrialFibrillationBurden,
            // Nutrition
            .dietaryFatTotal, .dietaryFatPolyunsaturated, .dietaryFatMonounsaturated,
            .dietaryFatSaturated, .dietaryCholesterol, .dietarySodium,
            .dietaryCarbohydrates, .dietaryFiber, .dietarySugar, .dietaryEnergyConsumed,
            .dietaryProtein, .dietaryVitaminA, .dietaryVitaminB6, .dietaryVitaminB12,
            .dietaryVitaminC, .dietaryVitaminD, .dietaryVitaminE, .dietaryVitaminK,
            .dietaryCalcium, .dietaryIron, .dietaryThiamin, .dietaryRiboflavin,
            .dietaryNiacin, .dietaryFolate, .dietaryBiotin, .dietaryPantothenicAcid,
            .dietaryPhosphorus, .dietaryIodine, .dietaryMagnesium, .dietaryZinc,
            .dietarySelenium, .dietaryCopper, .dietaryManganese, .dietaryChromium,
            .dietaryMolybdenum, .dietaryChloride, .dietaryPotassium, .dietaryCaffeine,
            .dietaryWater,
            // Hearing
            .environmentalAudioExposure, .headphoneAudioExposure,
            // Mobility
            .sixMinuteWalkTestDistance, .walkingSpeed, .walkingStepLength,
            .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
            .stairAscentSpeed, .stairDescentSpeed,
            // Reproductive health
            .basalBodyTemperature
        ]

        for identifier in quantityIdentifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }

        // iOS 17+ specific quantity types
        if #available(iOS 17.0, *) {
            let ios17Identifiers: [HKQuantityTypeIdentifier] = [
                .cyclingCadence, .cyclingFunctionalThresholdPower, .cyclingPower,
                .cyclingSpeed, .runningGroundContactTime, .runningPower,
                .runningSpeed, .runningStrideLength, .runningVerticalOscillation,
                .underwaterDepth, .waterTemperature, .timeInDaylight,
                .physicalEffort
            ]
            for identifier in ios17Identifiers {
                if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                    types.insert(type)
                }
            }
        }

        if #available(iOS 18.0, *) {
            let ios18Identifiers: [HKQuantityTypeIdentifier] = [
                .estimatedWorkoutEffortScore
            ]
            for identifier in ios18Identifiers {
                if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                    types.insert(type)
                }
            }
        }

        // --- Category types ---
        let categoryIdentifiers: [HKCategoryTypeIdentifier] = [
            // Sleep
            .sleepAnalysis,
            // Mindfulness
            .mindfulSession,
            // Female health
            .menstrualFlow, .cervicalMucusQuality, .ovulationTestResult,
            .pregnancyTestResult, .progesteroneTestResult, .intermenstrualBleeding,
            .persistentIntermenstrualBleeding, .prolongedMenstrualPeriods,
            .irregularMenstrualCycles, .infrequentMenstrualCycles,
            .lactation, .pregnancy, .contraceptive,
            // Symptoms
            .abdominalCramps, .acne, .appetiteChanges, .bladderIncontinence,
            .bloating, .breastPain, .chestTightnessOrPain, .chills,
            .constipation, .coughing, .diarrhea, .dizziness, .drySkin,
            .fainting, .fatigue, .fever, .generalizedBodyAche, .hairLoss,
            .headache, .heartburn, .hotFlashes, .lossOfSmell, .lossOfTaste,
            .lowerBackPain, .memoryLapse, .moodChanges, .nausea,
            .nightSweats, .pelvicPain, .rapidPoundingOrFlutteringHeartbeat,
            .runnyNose, .shortnessOfBreath, .sinusCongestion, .skippedHeartbeat,
            .sleepChanges, .soreThroat, .vaginalDryness, .vomiting,
            .wheezing,
            // Other
            .toothbrushingEvent, .handwashingEvent,
            .lowHeartRateEvent, .highHeartRateEvent,
            .irregularHeartRhythmEvent, .lowCardioFitnessEvent,
            .headphoneAudioExposureEvent,
            .appleWalkingSteadinessEvent,
            .environmentalAudioExposureEvent
        ]

        for identifier in categoryIdentifiers {
            if let type = HKCategoryType.categoryType(forIdentifier: identifier) {
                types.insert(type)
            }
        }

        if #available(iOS 18.0, *) {
            let ios18CategoryIdentifiers: [HKCategoryTypeIdentifier] = [
                .bleedingDuringPregnancy
            ]
            for identifier in ios18CategoryIdentifiers {
                if let type = HKCategoryType.categoryType(forIdentifier: identifier) {
                    types.insert(type)
                }
            }
        }

        // --- Workout type ---
        types.insert(HKWorkoutType.workoutType())

        return types
    }

    /// The least-privilege set offered to new users. Existing installs retain their
    /// previous full-data behavior until the user changes it deliberately.
    static func essentialSampleTypes() -> Set<HKSampleType> {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned,
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max
        ]
        var types = Set<HKSampleType>()
        for identifier in identifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        types.insert(HKWorkoutType.workoutType())
        return types
    }

    static var selectedScope: DataScope {
        // Existing installs completed onboarding before scoped consent existed;
        // preserve their full-data behavior. A new user who skipped authorization
        // still defaults to essentials when they grant access later.
        guard let raw = UserDefaults.standard.string(forKey: DataScope.storageKey) else {
            return UserDefaults.standard.bool(forKey: "hkb.onboardingComplete") ? .complete : .essentials
        }
        return DataScope(rawValue: raw) ?? .essentials
    }

    static func sampleTypes(for scope: DataScope = selectedScope) -> Set<HKSampleType> {
        scope == .essentials ? essentialSampleTypes() : allSampleTypes()
    }

    // MARK: - Authorization

    /// Requests read authorization only for the scope the user explicitly chose.
    /// Must be called from the main thread (presents HK auth sheet).
    ///
    /// The scope is persisted only after the request succeeds: a failed request must not
    /// leave SyncEngine querying a scope the user never actually authorized.
    func requestAuthorization(scope: DataScope = HealthKitManager.selectedScope) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }
        let readTypes = Self.sampleTypes(for: scope)
        try await store.requestAuthorization(toShare: [], read: readTypes)
        UserDefaults.standard.set(scope.rawValue, forKey: DataScope.storageKey)
    }

    /// Whether iOS would still present the authorization sheet for `scope`.
    ///
    /// This is the only API that answers the question for READ types —
    /// `authorizationStatus(for:)` deliberately hides read permission to avoid leaking
    /// which data a user has. Once every type in the scope has been asked about,
    /// requesting again is a silent no-op, and the UI must route to Settings instead.
    func needsAuthorizationRequest(scope: DataScope = HealthKitManager.selectedScope) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let readTypes = Set<HKObjectType>(Self.sampleTypes(for: scope))
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status == .shouldRequest
    }

    // MARK: - Sample query

    /// Queries HKSamples for a given type within a date range.
    /// - Parameters:
    ///   - sampleType: The HKSampleType to query.
    ///   - startDate: Query start (nil = earliest possible).
    ///   - endDate: Query end (nil = now).
    ///   - limit: Maximum number of results (0 = no limit / HKObjectQueryNoLimit).
    func querySamples(
        type sampleType: HKSampleType,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> [HKSample] {
        let predicate: NSPredicate?
        if let start = startDate, let end = endDate {
            predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        } else if let start = startDate {
            predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        } else {
            predicate = nil // queries all time
        }

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit == 0 ? HKObjectQueryNoLimit : limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results ?? [])
                }
            }
            self.store.execute(query)
        }
    }

    // MARK: - HKSample → HealthSample conversion

    /// Converts an HKSample into our serializable HealthSample struct.
    func convert(sample: HKSample) -> HealthSample? {
        let device = sample.device?.name
            ?? sample.sourceRevision.source.name

        let baseMetadata = buildBaseMetadata(from: sample)

        switch sample {
        case let qty as HKQuantitySample:
            return convertQuantitySample(qty, device: device, baseMetadata: baseMetadata)

        case let cat as HKCategorySample:
            return convertCategorySample(cat, device: device, baseMetadata: baseMetadata)

        case let workout as HKWorkout:
            return convertWorkout(workout, device: device, baseMetadata: baseMetadata)

        default:
            return nil
        }
    }

    // MARK: - Private conversion helpers

    private func buildBaseMetadata(from sample: HKSample) -> [String: AnyCodableValue] {
        var meta: [String: AnyCodableValue] = [:]
        if let rawMeta = sample.metadata {
            for (k, v) in rawMeta {
                if let encoded = AnyCodableValue.from(v) {
                    meta[k] = encoded
                }
            }
        }
        return meta
    }

    private func convertQuantitySample(
        _ sample: HKQuantitySample,
        device: String,
        baseMetadata: [String: AnyCodableValue]
    ) -> HealthSample? {
        let identifier = sample.quantityType.identifier
        let (value, unit) = bestUnit(for: sample.quantityType, quantity: sample.quantity)

        return HealthSample(
            metricType: identifier,
            value: value,
            unit: unit,
            sourceDevice: device,
            startedAt: sample.startDate,
            endedAt: sample.endDate,
            metadata: baseMetadata.isEmpty ? nil : baseMetadata
        )
    }

    private func convertCategorySample(
        _ sample: HKCategorySample,
        device: String,
        baseMetadata: [String: AnyCodableValue]
    ) -> HealthSample? {
        let identifier = sample.categoryType.identifier
        var meta = baseMetadata

        // Enrich sleep analysis with stage name
        if sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            let stageName = sleepStageName(value: sample.value)
            meta["sleep_stage"] = .string(stageName)
        }

        return HealthSample(
            metricType: identifier,
            value: Double(sample.value),
            unit: "category",
            sourceDevice: device,
            startedAt: sample.startDate,
            endedAt: sample.endDate,
            metadata: meta.isEmpty ? nil : meta
        )
    }

    private func convertWorkout(
        _ workout: HKWorkout,
        device: String,
        baseMetadata: [String: AnyCodableValue]
    ) -> HealthSample? {
        var meta = baseMetadata
        meta["workout_type"] = .string(workout.workoutActivityType.name)
        meta["duration_seconds"] = .double(workout.duration)

        if let distance = workout.totalDistance {
            meta["total_distance_meters"] = .double(distance.doubleValue(for: .meter()))
        }
        if let energy = workout.totalEnergyBurned {
            meta["total_energy_burned_cal"] = .double(energy.doubleValue(for: .kilocalorie()))
        }
        if let laps = workout.totalSwimmingStrokeCount {
            meta["total_swimming_stroke_count"] = .double(laps.doubleValue(for: .count()))
        }
        if let flights = workout.totalFlightsClimbed {
            meta["total_flights_climbed"] = .double(flights.doubleValue(for: .count()))
        }

        return HealthSample(
            metricType: HKWorkoutType.workoutType().identifier,
            value: workout.duration,
            unit: "seconds",
            sourceDevice: device,
            startedAt: workout.startDate,
            endedAt: workout.endDate,
            metadata: meta
        )
    }

    // MARK: - Unit selection

    /// Returns the most human-readable (value, unitString) pair for a quantity sample.
    private func bestUnit(
        for type: HKQuantityType,
        quantity: HKQuantity
    ) -> (Double, String) {
        // Map of identifier → preferred unit. `Self.unitMap`, not a local: this is called
        // once per sample and a backfill converts hundreds of thousands of them, so building
        // an ~120-entry dictionary here made the hot path allocate on every single record.
        let unitMap = Self.unitMap
        let identifier = type.identifier

        // iOS 18+ only, so it cannot live in the static map above. Its unit is its own
        // dimension: without this it matched nothing, fell past every fallback, and was
        // stored as (0.0, "unsupported") — a silent zero indistinguishable from real data.
        if #available(iOS 18.0, *),
           identifier == HKQuantityTypeIdentifier.estimatedWorkoutEffortScore.rawValue {
            let effort = HKUnit.appleEffortScore()
            if quantity.is(compatibleWith: effort) {
                return (quantity.doubleValue(for: effort), effort.unitString)
            }
        }

        if let preferredUnit = unitMap[identifier], quantity.is(compatibleWith: preferredUnit) {
            return (quantity.doubleValue(for: preferredUnit), preferredUnit.unitString)
        }

        // Fallback: try common units in order of specificity.
        //
        // `.gram()`, NOT `.gramUnit(with: .kilo)`. `is(compatibleWith:)` matches on DIMENSION,
        // not scale, so every unmapped mass quantity used to match kilograms: a 32 g protein
        // entry was stored as 0.032 kg. That is a truthful conversion — the unit travels with
        // the value — but it is the wrong unit for nutrition, it pushes micronutrients down to
        // ~1e-10, and a metric whose unit CHANGES between app versions is aggregated across
        // both units by the daily summariser. Grams is the HealthKit convention for dietary
        // mass, and every dietary identifier is now mapped explicitly below regardless.
        let fallbackUnits: [HKUnit] = [
            .count(), .kilocalorie(), .meter(), .gram(),
            .percent(), .second(), .minute(), .liter(), .degreeCelsius(),
            .millimeterOfMercury(), HKUnit(from: "count/min"),
            HKUnit.watt(), HKUnit(from: "m/s"), HKUnit(from: "L/min")
        ]
        for unit in fallbackUnits {
            if quantity.is(compatibleWith: unit) {
                return (quantity.doubleValue(for: unit), unit.unitString)
            }
        }

        // Last resort: count if compatible; otherwise return a placeholder to avoid NSException.
        guard quantity.is(compatibleWith: .count()) else {
            return (0.0, "unsupported")
        }
        return (quantity.doubleValue(for: .count()), "count")
    }

    /// Preferred unit per quantity identifier. Every dietary type is listed explicitly:
    /// leaving them to the fallback is what put nutrition into kilograms.
    private static let unitMap: [String: HKUnit] = [
            HKQuantityTypeIdentifier.stepCount.rawValue:                  .count(),
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:     .meter(),
            HKQuantityTypeIdentifier.distanceCycling.rawValue:            .meter(),
            HKQuantityTypeIdentifier.distanceSwimming.rawValue:           .meter(),
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:         .kilocalorie(),
            HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:          .kilocalorie(),
            HKQuantityTypeIdentifier.heartRate.rawValue:                  HKUnit(from: "count/min"),
            HKQuantityTypeIdentifier.restingHeartRate.rawValue:           HKUnit(from: "count/min"),
            HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue:    HKUnit(from: "count/min"),
            HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:   .init(from: "ms"),
            HKQuantityTypeIdentifier.oxygenSaturation.rawValue:           .percent(),
            HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:      .millimeterOfMercury(),
            HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:     .millimeterOfMercury(),
            HKQuantityTypeIdentifier.respiratoryRate.rawValue:            HKUnit(from: "count/min"),
            HKQuantityTypeIdentifier.bodyMass.rawValue:                   .gramUnit(with: .kilo),
            HKQuantityTypeIdentifier.bodyMassIndex.rawValue:              .count(),
            HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:          .percent(),
            HKQuantityTypeIdentifier.height.rawValue:                     .meter(),
            HKQuantityTypeIdentifier.leanBodyMass.rawValue:               .gramUnit(with: .kilo),
            HKQuantityTypeIdentifier.waistCircumference.rawValue:         .meter(),
            HKQuantityTypeIdentifier.bloodGlucose.rawValue:               HKUnit(from: "mg/dL"),
            HKQuantityTypeIdentifier.bodyTemperature.rawValue:            .degreeCelsius(),
            HKQuantityTypeIdentifier.basalBodyTemperature.rawValue:       .degreeCelsius(),
            HKQuantityTypeIdentifier.flightsClimbed.rawValue:             .count(),
            HKQuantityTypeIdentifier.pushCount.rawValue:                  .count(),
            HKQuantityTypeIdentifier.vo2Max.rawValue:                     HKUnit(from: "ml/kg·min"),
            HKQuantityTypeIdentifier.appleExerciseTime.rawValue:          .minute(),
            HKQuantityTypeIdentifier.appleStandTime.rawValue:             .minute(),
            HKQuantityTypeIdentifier.appleMoveTime.rawValue:              .minute(),
            HKQuantityTypeIdentifier.uvExposure.rawValue:                 .count(),
            HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue: HKUnit(from: "dBASPL"),
            HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue:     HKUnit(from: "dBASPL"),
            HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:      .kilocalorie(),
            HKQuantityTypeIdentifier.dietaryWater.rawValue:               .liter(),
            HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:            .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:  .meter(),
            HKQuantityTypeIdentifier.walkingSpeed.rawValue:               HKUnit(from: "m/s"),
            HKQuantityTypeIdentifier.stairAscentSpeed.rawValue:           HKUnit(from: "m/s"),
            HKQuantityTypeIdentifier.stairDescentSpeed.rawValue:          HKUnit(from: "m/s"),
            HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue: .percent(),
            HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue: .percent(),
            HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue:     .percent(),
            HKQuantityTypeIdentifier.walkingStepLength.rawValue:          .meter(),
            // Activity extras
            HKQuantityTypeIdentifier.distanceDownhillSnowSports.rawValue: .meter(),
            HKQuantityTypeIdentifier.distanceWheelchair.rawValue:         .meter(),
            HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue:        .count(),
            HKQuantityTypeIdentifier.nikeFuel.rawValue:                   .count(),
            // Vitals/results
            HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue:   .percent(),
            HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:        .liter(),
            HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue:    .liter(),
            HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:     HKUnit(from: "L/min"),
            HKQuantityTypeIdentifier.inhalerUsage.rawValue:               .count(),
            HKQuantityTypeIdentifier.bloodAlcoholContent.rawValue:        .percent(),
            HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue:        .count(),
            HKQuantityTypeIdentifier.atrialFibrillationBurden.rawValue:   .percent(),
            // iOS 17+ cycling / running (Watts, m/s, ms, cm)
            HKQuantityTypeIdentifier.cyclingPower.rawValue:               HKUnit.watt(),
            HKQuantityTypeIdentifier.runningPower.rawValue:               HKUnit.watt(),
            HKQuantityTypeIdentifier.cyclingFunctionalThresholdPower.rawValue: HKUnit.watt(),
            HKQuantityTypeIdentifier.cyclingCadence.rawValue:             HKUnit(from: "count/min"),
            HKQuantityTypeIdentifier.cyclingSpeed.rawValue:               HKUnit(from: "m/s"),
            HKQuantityTypeIdentifier.runningSpeed.rawValue:               HKUnit(from: "m/s"),
            HKQuantityTypeIdentifier.runningStrideLength.rawValue:        .meter(),
            HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue: HKUnit(from: "cm"),
            HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:   HKUnit(from: "ms"),
            HKQuantityTypeIdentifier.underwaterDepth.rawValue:            .meter(),
            HKQuantityTypeIdentifier.waterTemperature.rawValue:           .degreeCelsius(),
            HKQuantityTypeIdentifier.timeInDaylight.rawValue:             .minute(),
            HKQuantityTypeIdentifier.physicalEffort.rawValue:             HKUnit(from: "kcal/hr·kg"),
            // Nutrition — grams
            HKQuantityTypeIdentifier.dietaryFatTotal.rawValue:            .gram(),
            HKQuantityTypeIdentifier.dietaryFatPolyunsaturated.rawValue:  .gram(),
            HKQuantityTypeIdentifier.dietaryFatMonounsaturated.rawValue:  .gram(),
            HKQuantityTypeIdentifier.dietaryFatSaturated.rawValue:        .gram(),
            HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue:       .gram(),
            HKQuantityTypeIdentifier.dietaryFiber.rawValue:               .gram(),
            HKQuantityTypeIdentifier.dietarySugar.rawValue:               .gram(),
            HKQuantityTypeIdentifier.dietaryProtein.rawValue:             .gram(),
            // Nutrition — milligrams
            HKQuantityTypeIdentifier.dietaryCholesterol.rawValue:      .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietarySodium.rawValue:           .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryCalcium.rawValue:          .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryIron.rawValue:             .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryPotassium.rawValue:        .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryChloride.rawValue:         .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryMagnesium.rawValue:        .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryPhosphorus.rawValue:       .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryZinc.rawValue:             .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryVitaminC.rawValue:         .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryVitaminE.rawValue:         .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryNiacin.rawValue:           .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryPantothenicAcid.rawValue:  .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryRiboflavin.rawValue:       .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryThiamin.rawValue:          .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryVitaminB6.rawValue:        .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryCopper.rawValue:           .gramUnit(with: .milli),
            HKQuantityTypeIdentifier.dietaryManganese.rawValue:        .gramUnit(with: .milli),
            // Nutrition — micrograms
            HKQuantityTypeIdentifier.dietaryVitaminA.rawValue:    .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryVitaminB12.rawValue:  .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryVitaminD.rawValue:    .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryVitaminK.rawValue:    .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryBiotin.rawValue:      .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryChromium.rawValue:    .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryFolate.rawValue:      .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryIodine.rawValue:      .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietaryMolybdenum.rawValue:  .gramUnit(with: .micro),
            HKQuantityTypeIdentifier.dietarySelenium.rawValue:    .gramUnit(with: .micro),
            // Non-mass types that also had no mapping and fell through to a bare count
            HKQuantityTypeIdentifier.insulinDelivery.rawValue:            .internationalUnit(),
            HKQuantityTypeIdentifier.electrodermalActivity.rawValue:      .siemenUnit(with: .micro),
        ]

    // MARK: - Sleep stage name

    private func sleepStageName(value: Int) -> String {
        switch value {
        case HKCategoryValueSleepAnalysis.inBed.rawValue:           return "HKCategoryValueSleepAnalysisInBed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return "HKCategoryValueSleepAnalysisAsleepUnspecified"
        case HKCategoryValueSleepAnalysis.awake.rawValue:           return "HKCategoryValueSleepAnalysisAwake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:      return "HKCategoryValueSleepAnalysisAsleepCore"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:      return "HKCategoryValueSleepAnalysisAsleepDeep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:       return "HKCategoryValueSleepAnalysisAsleepREM"
        default:                                                      return "HKCategoryValueSleepAnalysisUnknown"
        }
    }
}

// MARK: - HKWorkoutActivityType + name

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .americanFootball:        return "HKWorkoutActivityTypeAmericanFootball"
        case .archery:                 return "HKWorkoutActivityTypeArchery"
        case .australianFootball:      return "HKWorkoutActivityTypeAustralianFootball"
        case .badminton:               return "HKWorkoutActivityTypeBadminton"
        case .baseball:                return "HKWorkoutActivityTypeBaseball"
        case .basketball:              return "HKWorkoutActivityTypeBasketball"
        case .bowling:                 return "HKWorkoutActivityTypeBowling"
        case .boxing:                  return "HKWorkoutActivityTypeBoxing"
        case .climbing:                return "HKWorkoutActivityTypeClimbing"
        case .cricket:                 return "HKWorkoutActivityTypeCricket"
        case .crossTraining:           return "HKWorkoutActivityTypeCrossTraining"
        case .curling:                 return "HKWorkoutActivityTypeCurling"
        case .cycling:                 return "HKWorkoutActivityTypeCycling"
        case .dance:                   return "HKWorkoutActivityTypeDance"
        case .elliptical:              return "HKWorkoutActivityTypeElliptical"
        case .equestrianSports:        return "HKWorkoutActivityTypeEquestrianSports"
        case .fencing:                 return "HKWorkoutActivityTypeFencing"
        case .fishing:                 return "HKWorkoutActivityTypeFishing"
        case .functionalStrengthTraining: return "HKWorkoutActivityTypeFunctionalStrengthTraining"
        case .golf:                    return "HKWorkoutActivityTypeGolf"
        case .gymnastics:              return "HKWorkoutActivityTypeGymnastics"
        case .handball:                return "HKWorkoutActivityTypeHandball"
        case .hiking:                  return "HKWorkoutActivityTypeHiking"
        case .hockey:                  return "HKWorkoutActivityTypeHockey"
        case .hunting:                 return "HKWorkoutActivityTypeHunting"
        case .lacrosse:                return "HKWorkoutActivityTypeLacrosse"
        case .martialArts:             return "HKWorkoutActivityTypeMartialArts"
        case .mindAndBody:             return "HKWorkoutActivityTypeMindAndBody"
        case .mixedCardio:             return "HKWorkoutActivityTypeMixedCardio"
        case .paddleSports:            return "HKWorkoutActivityTypePaddleSports"
        case .play:                    return "HKWorkoutActivityTypePlay"
        case .preparationAndRecovery:  return "HKWorkoutActivityTypePreparationAndRecovery"
        case .racquetball:             return "HKWorkoutActivityTypeRacquetball"
        case .rowing:                  return "HKWorkoutActivityTypeRowing"
        case .rugby:                   return "HKWorkoutActivityTypeRugby"
        case .running:                 return "HKWorkoutActivityTypeRunning"
        case .sailing:                 return "HKWorkoutActivityTypeSailing"
        case .skatingSports:           return "HKWorkoutActivityTypeSkatingSports"
        case .snowSports:              return "HKWorkoutActivityTypeSnowSports"
        case .soccer:                  return "HKWorkoutActivityTypeSoccer"
        case .softball:                return "HKWorkoutActivityTypeSoftball"
        case .squash:                  return "HKWorkoutActivityTypeSquash"
        case .stairClimbing:           return "HKWorkoutActivityTypeStairClimbing"
        case .surfingSports:           return "HKWorkoutActivityTypeSurfingSports"
        case .swimming:                return "HKWorkoutActivityTypeSwimming"
        case .tableTennis:             return "HKWorkoutActivityTypeTableTennis"
        case .tennis:                  return "HKWorkoutActivityTypeTennis"
        case .trackAndField:           return "HKWorkoutActivityTypeTrackAndField"
        case .traditionalStrengthTraining: return "HKWorkoutActivityTypeTraditionalStrengthTraining"
        case .volleyball:              return "HKWorkoutActivityTypeVolleyball"
        case .walking:                 return "HKWorkoutActivityTypeWalking"
        case .waterFitness:            return "HKWorkoutActivityTypeWaterFitness"
        case .waterPolo:               return "HKWorkoutActivityTypeWaterPolo"
        case .waterSports:             return "HKWorkoutActivityTypeWaterSports"
        case .wrestling:               return "HKWorkoutActivityTypeWrestling"
        case .yoga:                    return "HKWorkoutActivityTypeYoga"
        case .barre:                   return "HKWorkoutActivityTypeBarre"
        case .coreTraining:            return "HKWorkoutActivityTypeCoreTraining"
        case .crossCountrySkiing:      return "HKWorkoutActivityTypeCrossCountrySkiing"
        case .downhillSkiing:          return "HKWorkoutActivityTypeDownhillSkiing"
        case .flexibility:             return "HKWorkoutActivityTypeFlexibility"
        case .highIntensityIntervalTraining: return "HKWorkoutActivityTypeHighIntensityIntervalTraining"
        case .jumpRope:                return "HKWorkoutActivityTypeJumpRope"
        case .kickboxing:              return "HKWorkoutActivityTypeKickboxing"
        case .pilates:                 return "HKWorkoutActivityTypePilates"
        case .snowboarding:            return "HKWorkoutActivityTypeSnowboarding"
        case .stairs:                  return "HKWorkoutActivityTypeStairs"
        case .stepTraining:            return "HKWorkoutActivityTypeStepTraining"
        case .wheelchairWalkPace:      return "HKWorkoutActivityTypeWheelchairWalkPace"
        case .wheelchairRunPace:       return "HKWorkoutActivityTypeWheelchairRunPace"
        case .taiChi:                  return "HKWorkoutActivityTypeTaiChi"
        case .mixedMetabolicCardioTraining: return "HKWorkoutActivityTypeMixedMetabolicCardioTraining"
        case .discSports:              return "HKWorkoutActivityTypeDiscSports"
        case .fitnessGaming:           return "HKWorkoutActivityTypeFitnessGaming"
        case .cardioDance:             return "HKWorkoutActivityTypeCardioDance"
        case .socialDance:             return "HKWorkoutActivityTypeSocialDance"
        case .pickleball:              return "HKWorkoutActivityTypePickleball"
        case .cooldown:                return "HKWorkoutActivityTypeCooldown"
        case .swimBikeRun:             return "HKWorkoutActivityTypeSwimBikeRun"
        case .transition:              return "HKWorkoutActivityTypeTransition"
        case .underwaterDiving:        return "HKWorkoutActivityTypeUnderwaterDiving"
        case .other:                   return "HKWorkoutActivityTypeOther"
        default:                       return "HKWorkoutActivityTypeUnknown"
        }
    }
}

// MARK: - Cumulative types: HealthKit's own merged hourly totals

extension HealthKitManager {

    /// Stored in `source_device` for a total HealthKit computed across every source.
    static let allSourcesLabel = "HealthKit (all sources)"

    enum HourlyTotalsError: LocalizedError {
        case calendarArithmetic
        case noStatistics

        var errorDescription: String? {
            switch self {
            case .calendarArithmetic: return "Could not compute an hour boundary"
            case .noStatistics:       return "HealthKit returned no statistics"
            }
        }
    }

    /// Activity types that several devices record at the same moment. Keep in step with
    /// DOUBLE_COUNTED_ACTIVITY_TYPES in scripts/import_health_export.py.
    ///
    /// Deliberately a list, not `aggregationStyle == .cumulative`. Nutrition, insulin and
    /// the other cumulative types are logged one entry at a time by one app, are not
    /// double-counted, and carry metadata (meal, insulin delivery reason, user-entered)
    /// that an hourly total would throw away for good.
    static let doubleCountedActivityIdentifiers: Set<String> = [
        HKQuantityTypeIdentifier.stepCount.rawValue,
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
        HKQuantityTypeIdentifier.distanceCycling.rawValue,
        HKQuantityTypeIdentifier.distanceSwimming.rawValue,
        HKQuantityTypeIdentifier.distanceWheelchair.rawValue,
        HKQuantityTypeIdentifier.distanceDownhillSnowSports.rawValue,
        HKQuantityTypeIdentifier.pushCount.rawValue,
        HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue,
        HKQuantityTypeIdentifier.flightsClimbed.rawValue,
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
        HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
        HKQuantityTypeIdentifier.appleMoveTime.rawValue,
        HKQuantityTypeIdentifier.appleStandTime.rawValue,
    ]

    /// Whether a type syncs as hourly totals instead of individual samples.
    ///
    /// Summing individual samples double-counts whenever two devices record the same
    /// activity: an iPhone in the pocket and a Watch on the wrist both count the same steps,
    /// and Apple Health shows one figure only because its statistics queries take one source
    /// per stretch of time. Measured on real data 2026-09-12: across 2021 the stored sample
    /// sums averaged 13,392 steps/day against ~8,015 once iPhone samples overlapping Watch
    /// samples were dropped, +67%. Only the HKStatisticsQuery family applies that merge, so
    /// for these types the app posts what it returns. Register D361.
    static func syncsAsHourlyTotals(_ type: HKSampleType) -> Bool {
        type is HKQuantityType && doubleCountedActivityIdentifiers.contains(type.identifier)
    }

    /// Hour boundaries are UTC, never the device's zone. In local time the same instant
    /// floors to a different `started_at` after a move to a half-hour zone (India, +5:30),
    /// and the DST fall-back hour is ambiguous; either one produces a second row under a
    /// new upsert key instead of replacing the first. Every whole-hour zone, America/New_York
    /// included, puts its day boundaries on UTC hours, so daily totals are unaffected.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// One HealthSample per UTC hour touched by `samples`, carrying HealthKit's merged
    /// cumulative sum for that WHOLE hour.
    ///
    /// The whole hour, not the new samples' share of it, is what makes a re-post idempotent:
    /// the ingest upsert key is (user, metric_type, source_device, started_at), so a later
    /// sample in the same hour replaces that hour's total instead of adding to it.
    ///
    /// NOT corrected: a sample DELETED from Health. The anchored query reports a deletion
    /// only as a UUID with no dates, so nothing here knows which hour to re-post, and the
    /// stored total keeps the deleted amount until a new sample lands in that hour. That gap
    /// predates hourly totals (per-device rows were never deleted either). Register D361.
    ///
    /// `notBefore` is the import horizon's sweep floor. The statistics query below starts
    /// at the earliest touched hour, and a sample that straddles the floor (live sync's
    /// predicate matches overlap, not strict start) would otherwise pull hours from before
    /// it. Hours starting before the floor's own hour are dropped, so the collection query
    /// never reaches earlier than the floor on either path. nil means unbounded.
    func hourlyTotals(for type: HKQuantityType, touchedBy samples: [HKSample],
                      notBefore floor: Date?) async throws -> [HealthSample] {
        let calendar = Self.utcCalendar
        var hours = Set<Date>()
        var unitString: String?
        let floorHour: Date?
        if let floor {
            guard let start = calendar.dateInterval(of: .hour, for: floor)?.start else {
                throw HourlyTotalsError.calendarArithmetic
            }
            floorHour = start
        } else {
            floorHour = nil
        }

        for sample in samples {
            if unitString == nil, let quantitySample = sample as? HKQuantitySample {
                unitString = bestUnit(for: type, quantity: quantitySample.quantity).1
            }
            guard var hour = calendar.dateInterval(of: .hour, for: sample.startDate)?.start else {
                throw HourlyTotalsError.calendarArithmetic
            }
            // Every hour the sample overlaps. A sample ending exactly on a boundary does
            // not touch the next hour; a zero-length sample still touches its own.
            repeat {
                // An hour before the horizon is not this path's to send.
                if floorHour.map({ hour >= $0 }) ?? true {
                    hours.insert(hour)
                }
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else {
                    throw HourlyTotalsError.calendarArithmetic
                }
                hour = next
            } while hour < sample.endDate
        }
        guard let unitString, !hours.isEmpty else { return [] }

        // Query in spans of at most 31 days. A first-sync page can touch hours years apart,
        // and one collection query across all of them would build every empty hour between.
        let sorted = hours.sorted()
        var results: [HealthSample] = []
        var chunkStart = 0
        while chunkStart < sorted.count {
            guard let limit = calendar.date(byAdding: .day, value: 31, to: sorted[chunkStart]) else {
                throw HourlyTotalsError.calendarArithmetic
            }
            var chunkEnd = chunkStart
            while chunkEnd + 1 < sorted.count, sorted[chunkEnd + 1] < limit { chunkEnd += 1 }

            let first = sorted[chunkStart]
            guard let end = calendar.date(byAdding: .hour, value: 1, to: sorted[chunkEnd]) else {
                throw HourlyTotalsError.calendarArithmetic
            }
            let collection = try await hourlyStatistics(for: type, from: first, to: end)

            for hour in sorted[chunkStart...chunkEnd] {
                guard let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hour) else {
                    throw HourlyTotalsError.calendarArithmetic
                }
                var value = 0.0
                var unit = unitString
                if let sum = collection.statistics(for: hour)?.sumQuantity() {
                    (value, unit) = bestUnit(for: type, quantity: sum)
                }
                results.append(HealthSample(
                    metricType: type.identifier,
                    value: value,
                    unit: unit,
                    sourceDevice: Self.allSourcesLabel,
                    startedAt: hour,
                    endedAt: hourEnd,
                    metadata: ["h4ai_aggregation": .string("hkstatistics_cumulative_sum_hourly")]
                ))
            }
            chunkStart = chunkEnd + 1
        }
        return results
    }

    private func hourlyStatistics(
        for type: HKQuantityType,
        from start: Date,
        to end: Date
    ) async throws -> HKStatisticsCollection {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: DateComponents(hour: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let collection {
                    continuation.resume(returning: collection)
                } else {
                    continuation.resume(throwing: HourlyTotalsError.noStatistics)
                }
            }
            store.execute(query)
        }
    }
}
