/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 A data controller that manages reading and writing data from the HealthKit store.
 */

import Foundation
import HealthKit
import os

// The key used to save and load anchor objects from user defaults.
private let anchorKey = "anchorKey"

// The HealthKit store.
private let store = HKHealthStore()
private let isAvailable = HKHealthStore.isHealthDataAvailable()

// Caffeine types, used to read and write caffeine samples.
private let caffeineType = HKObjectType.quantityType(forIdentifier: .dietaryCaffeine)!
private let types: Set<HKSampleType> = [caffeineType]

// Milligram units.
private let miligrams = HKUnit.gramUnit(with: .milli)


// really the backend of the app
actor HealthKitController {
    
    let logger = Logger(subsystem: "com.example.apple-samplecode.Coffee-Tracker.watchkitapp.watchkitextension.HealthKitController",
                        category: "HealthKit")
    
    // MARK: - Properties
    
    // A weak link to the main model.
    private weak var model: CoffeeData?
    
    // Indicates whether the user has authroized access to their health data
    private lazy var isAuthorized = false
    
    // An anchor object, used to download just the changes since the last time.
    private var anchor: HKQueryAnchor? {
        get {
            // If user defaults returns nil, just return it.
            guard let data = UserDefaults.standard.object(forKey: anchorKey) as? Data else {
                return nil
            }
            
            // Otherwise, unarchive and return the data object.
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
            } catch {
                // If an error occurs while unarchiving, log the error and return nil.
                logger.error("Unable to unarchive \(data): \(error.localizedDescription)")
                return nil
            }
        }
        set(newAnchor) {
            // If the new value is nil, save it.
            guard let newAnchor = newAnchor else {
                UserDefaults.standard.set(nil, forKey: anchorKey)
                return
            }
            
            // Otherwise convert the anchor object to Data, and save it in user defaults.
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                UserDefaults.standard.set(data, forKey: anchorKey)
            } catch {
                // If an error occurs while archiving the anchor, just log the error.
                // the value stored in user defaults is not changed.
                logger.error("Unable to archive \(newAnchor): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Initializers
    
    // The HealthKit controller's initializer.
    init(withModel model: CoffeeData) {
        self.model = model
    }
    
    // MARK: - Public Methods
    
    // Request authorization to read and save the required data types.
    // these are not a part of the Actor protected state so they can be called from other parts of the code
    @available(*, deprecated, message: "Prefer async alternative instead")
    // do not change actor state -- not part of the actor protected state
    nonisolated public func requestAuthorization(completionHandler: @escaping (Bool) -> Void ) {
        async {
            let result = await requestAuthorization()
            completionHandler(result)
        }
    }
    
    // this still could have race condtion issues
    // Swift will automatically choose the correct async func
    public func requestAuthorization() async -> Bool {
        // we must return value
        guard isAvailable else { return false }
        
        do {
            try await store.requestAuthorization(toShare: types, read: types)
            // Check for any errors.
            // Set the authorization property, and call the handler.
            self.isAuthorized = true
            return true
        } catch let error1 {
            self.logger.error("An error occurred while requesting HealthKit Authorization: \(error1.localizedDescription)")
            return false
        }
    }
    
    // Async reads data from the HealthKit store.
    @available(*, deprecated, message: "Prefer async alternative instead")
    // do not change actor state -- not part of the actor protected state -- can be called from outside actor
    nonisolated public func loadNewDataFromHealthKit( completionHandler: @escaping (Bool) -> Void = { _ in }) {
        // print (isAuthorized) // uncommnt to see error
        async { completionHandler(await self.loadNewDataFromHealthKit())}
    }
    
    /*
     This will make it async / thow and return the useful values
     */
    private func queryHealthKit() async throws -> ([HKSample]?, [HKDeletedObject]?, HKQueryAnchor?) {
        return try await withCheckedThrowingContinuation { continuation in
            // Create a predicate that only returns samples created within the last 24 hours.
            let endDate = Date()
            let startDate = endDate.addingTimeInterval(-24.0 * 60.0 * 60.0)
            let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate, .strictEndDate])
            
            // Create the query.
            let query = HKAnchoredObjectQuery(
                type: caffeineType,
                predicate: datePredicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit) { (_, samples, deletedSamples, newAnchor, error) in
                
                // When the query ends, check for errors.
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples, deletedSamples, newAnchor))
                }
            }
            // we want to await the query
            store.execute(query)
        }
    }
    
    // Reads data from the HealthKit store.
    // Reads data from the HealthKit store.
    @discardableResult
    public func loadNewDataFromHealthKit() async -> Bool {
        
        guard isAvailable else {
            logger.debug("HealthKit is not available on this device.")
            return false
        }
        
        logger.debug("Loading data from HealthKit")
        
        do {
            let (samples, deletedSamples, newAnchor) = try await queryHealthKit()
            // Update the anchor.
            self.anchor = newAnchor
            
            // Convert new caffeine samples into Drink instances
            // create an immutalbe copy
            let newDrinks: [Drink]
            if let samples = samples {
                newDrinks = self.drinksToAdd(from: samples)
            } else {
                newDrinks = []
            }
            
            // Create a set of UUIDs for any samples deleted from HealthKit.
            let deletedDrinks = self.drinksToDelete(from: deletedSamples ?? [])
            
            // Update the data on the main queue.
            // DispatchQueue.main.async
            // await MainActor.run {}
            // self.updateModel(newDrinks: newDrinks, deletedDrinks: deletedDrinks)
            
            // await is used on a synchronous function Model but must suspend to get on the main dispach que
            await model?.updateModel(newDrinks: newDrinks, deletedDrinks: deletedDrinks)
            return true
        } catch {
            self.logger.error("An error occurred while querying for samples: \(error.localizedDescription)")
            return false
        }
    }
    
    // Save a drink to HealthKit as a caffeine sample.
    public func save(drink: Drink) async {
        
        // Make sure HealthKit is available and authorized.
        guard isAvailable else { return }
        guard store.authorizationStatus(for: caffeineType) == .sharingAuthorized else { return }
        
        // Create metadata to hold the drink's UUID.
        // Use the sync identifier to remove drinks if they are deleted from
        // HealthKit.
        let metadata: [String: Any] = [HKMetadataKeySyncIdentifier: drink.uuid.uuidString,
                                          HKMetadataKeySyncVersion: 1]
        
        // Create a quantity object for the amount of caffeine in the drink.
        let mgCaffeine = HKQuantity(unit: miligrams, doubleValue: drink.mgCaffeine)
        
        // Create the caffeine sample.
        let caffeineSample = HKQuantitySample(type: caffeineType,
                                              quantity: mgCaffeine,
                                              start: drink.date,
                                              end: drink.date,
                                              metadata: metadata)
        
        // Save the sample to the HealthKit store.
        // takes a completion handler with success and error (remember to unwrap error)
        // We want to throw!
        do {
            try await store.save(caffeineSample)
            self.logger.debug("\(mgCaffeine) mg Drink saved to HealthKit")
        } catch {
            self.logger.error("Unable to save \(caffeineSample) to the HealthKit store: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    // Take an array of caffeine samples and returns an array of drinks.
    private func drinksToAdd(from samples: [HKSample]) -> [Drink] {
        
        // Filter out any samples saved by this app.
        let newSamples = samples.filter { sample in
            sample.sourceRevision.source != HKSource.default()
        }
        
        logger.debug("\(newSamples.count) samples not from this app!")
        
        let quantitySamples = newSamples.compactMap { sample in
            sample as? HKQuantitySample
        }
        
        logger.debug("\(quantitySamples.count) samples are quantity samples")
        
        // Return each sample, converted into a drink
        return quantitySamples.map { sample in
            Drink(mgCaffeine: sample.quantity.doubleValue(for: miligrams),
                  onDate: sample.startDate,
                  uuid: sample.uuid)
        }
    }
    
    // For any drinks deleted from the HealthKit store, this also deletes them from the app's data.
    private func drinksToDelete(from samples: [HKDeletedObject]) -> Set<UUID> {
        let uuidsToDelete = samples.lazy.map { deletedObject -> UUID in
            // Prefer HKMetadataKeySyncIdentifier if available
            let uuidString = deletedObject.metadata?[HKMetadataKeySyncIdentifier] as? String ?? ""
            return UUID(uuidString: uuidString) ?? deletedObject.uuid
        }
        
        logger.debug("\(uuidsToDelete.count) drinks deleted from HealthKit.")
        
        return Set(uuidsToDelete)
    }
    
}
