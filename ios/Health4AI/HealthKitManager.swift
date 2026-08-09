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
    func requestAuthorization(scope: DataScope = HealthKitManager.selectedScope) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HKError(.errorHealthDataUnavailable)
        }
        UserDefaults.standard.set(scope.rawValue, forKey: DataScope.storageKey)
        let readTypes = Self.sampleTypes(for: scope)
        try await store.requestAuthorization(toShare: [], read: readTypes)
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
        // Map of identifier → preferred unit
        let unitMap: [String: HKUnit] = [
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
        ]

        let identifier = type.identifier
        if let preferredUnit = unitMap[identifier], quantity.is(compatibleWith: preferredUnit) {
            return (quantity.doubleValue(for: preferredUnit), preferredUnit.unitString)
        }

        // Fallback: try common units in order of specificity
        let fallbackUnits: [HKUnit] = [
            .count(), .kilocalorie(), .meter(), .gramUnit(with: .kilo),
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
