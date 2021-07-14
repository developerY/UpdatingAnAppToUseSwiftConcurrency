/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A data object that tracks the number of drinks that the user has drunk.
*/

import SwiftUI
import ClockKit
import os

private let floatFormatter = FloatingPointFormatStyle().precision(.significantDigits(1...3))


private actor CoffeeDataStore {
    let logger = Logger(subsystem: "com.example.apple-samplecode.Coffee-Tracker.watchkitapp.watchkitextension.CoffeeDataStore", category: "ModelIO")
    
    // Use this value to determine whether you have changes that can be saved to disk.
    private var savedValue: [Drink] = []

    // Begin saving the drink data to disk.
    // Actors communicte by passing valuse (messages) to each other
    func save(_ currentDrinks: [Drink]) {
        
        // Don't save the data if there haven't been any changes.
        // used by both the save and load so need protection by Actor
        if currentDrinks == savedValue {
            logger.debug("The drink list hasn't changed. No need to save.")
            return
        }
        
        // Save as a binary plist file.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        
        let data: Data
        
        do {
            // Encode the currentDrinks array.
            data = try encoder.encode(currentDrinks)
        } catch {
            logger.error("An error occurred while encoding the data: \(error.localizedDescription)")
            return
        }
        
        // Save the data to disk as a binary plist file.
        do {
            // Write the data to disk
            try data.write(to: self.dataURL, options: [.atomic])

            // Update the saved value.
            savedValue = currentDrinks
            
            self.logger.debug("Saved!")
        } catch {
            self.logger.error("An error occurred while saving the data: \(error.localizedDescription)")
        }
        
    }
    
    // Begin loading the data from disk.
    func load() -> [Drink]{
        // Read the data from a background queue. This is using global reasoning ... better use the actor
        logger.debug("Loading the model.")
    
        var drinks: [Drink]
        
        do {
            // Load the drink data from a binary plist file.
            let data = try Data(contentsOf: self.dataURL)
            
            // Decode the data.
            let decoder = PropertyListDecoder()
            drinks = try decoder.decode([Drink].self, from: data)
            logger.debug("Data loaded from disk")
        } catch CocoaError.fileReadNoSuchFile {
            logger.debug("No file found--creating an empty drink list.")
            drinks = []
        } catch {
            fatalError("*** An unexpected error occurred while loading the drink list: \(error.localizedDescription) ***")
        }

        // Update the saved value.
        // Actor-isolated property 'savedValue' can only be mutated from inside the actor
        // store.savedValue = drinks
        savedValue = drinks
    
        return drinks
    }
    
    // Returns the URL for the plist file that stores the drink data.
    private var dataURL: URL {
        get throws {
            try FileManager
                   .default
                   .url(for: .documentDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: false)
                   // Append the file name to the directory.
                   .appendingPathComponent("CoffeeTracker.plist")
        }
    }
    
}

// The data model for the Coffee Tracker app.
@MainActor // guarantees everything runs on the Main Thread
class CoffeeData: ObservableObject {
    
    let logger = Logger(subsystem: "com.example.apple-samplecode.Coffee-Tracker.watchkitapp.watchkitextension.CoffeeData", category: "Model")
    
    // The data model needs to be accessed both from the app extension
    // and from the complication controller.
    static let shared = CoffeeData()
    lazy var healthKitController = HealthKitController(withModel: self)
    
    // An actor used to save and load the model data away from the main thread.
    private let store = CoffeeDataStore()
    
    // A background queue used to save and load the model data.
    // private var background = DispatchQueue(label: "Background Queue", qos: .userInitiated)
    
    // The list of drinks consumed.
    // Because this is @Published property,
    // Combine notifies any observers when a change occurs.
    @Published public private(set) var currentDrinks: [Drink] = []
        
    private func drinksUpdated() async {
        logger.debug("A value has been assigned to the current drinks property.")
        
        // Update any complications on active watch faces.
        let server = CLKComplicationServer.sharedInstance()
        for complication in server.activeComplications ?? [] {
            server.reloadTimeline(for: complication)
        }
        
        // Begin saving the data.
        // may suspend and other operations can run!
        await store.save(currentDrinks)
    }
    
    
    // The current level of caffeine in milligrams.
    // This property is calculated based on the currentDrinks array.
    public var currentMGCaffeine: Double {
        mgCaffeine(atDate: Date())
    }
    
    // A user-readable string representing the current amount of
    // caffeine in the user's body.
    public var currentMGCaffeineString: String {
        currentMGCaffeine.formatted(floatFormatter)
    }
    
    // Calculate the amount of caffeine in the user's system at the specified date.
    // The amount of caffeine is calculated from the currentDrinks array.
    public func mgCaffeine(atDate date: Date) -> Double {
        currentDrinks.reduce(0.0) {
            total, drink in total + drink.caffeineRemaining(at: date)
        }
    }

    // Return a user-readable string that describes the amount of caffeine in the user's
    // system at the specified date.
    public func mgCaffeineString(atDate date: Date) -> String {
        mgCaffeine(atDate: date).formatted(floatFormatter)
    }
    
    // Return the total number of drinks consumed today.
    // The value is in the equivalent number of 8 oz. cups of coffee.
    public var totalCupsToday: Double {
        
        // Calculate midnight this morning.
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        
        // Filter the drinks.
        let drinks = currentDrinks.filter { midnight < $0.date }
        
        // Get the total caffeine dose.
        let totalMG = drinks.reduce(0.0) { $0 + $1.mgCaffeine }
        
        // Convert mg caffeine to equivalent cups.
        return totalMG / DrinkType.smallCoffee.mgCaffeinePerServing
    }
    
    // Return the total equivalent cups of coffee as a user-readable string.
    public var totalCupsTodayString: String {
        totalCupsToday.formatted(floatFormatter)
    }
    
    // Return green, yellow, or red depending on the caffeine dose.
    public func color(forCaffeineDose dose: Double) -> UIColor {
        if dose < 200.0 {
            return .green
        } else if dose < 400.0 {
            return .yellow
        } else {
            return .red
        }
    }
    
    // Return green, yellow, or red depending on the total daily cups of  coffee.
    public func color(forTotalCups cups: Double) -> UIColor {
        if cups < 3.0 {
            return .green
        } else if cups < 5.0 {
            return .yellow
        } else {
            return .red
        }
    }
    
    // Add a drink to the list of drinks.
    public func addDrink(mgCaffeine: Double, onDate date: Date) {
        logger.debug("Adding a drink.")
        
        // Create a local array to hold the changes.
        var drinks = currentDrinks
        
        // Create a new drink and add it to the array.
        let drink = Drink(mgCaffeine: mgCaffeine, onDate: date)
        drinks.append(drink)
        
        // Get rid of any drinks that are 24 hours old.
        drinks.removeOutdatedDrinks()
        
        currentDrinks = drinks
        
        // Save drink information to HealthKit.
        // everything here needs to be self contained
        // make sure you are not touching global state
        async {
            await self.healthKitController.save(drink: drink)
            await self.drinksUpdated()
        }
    }
    
    // Update the model.
    // let the compiler do this for you.
    public func updateModel(newDrinks: [Drink], deletedDrinks: Set<UUID>) async {
        // func is running on the main thread !!!
        // assert(Thread.main == Thread.current, "Must be run on the main queue because it accesses currentDrinks.")
        // no longer needed with @MainAtor
        
        guard !newDrinks.isEmpty && !deletedDrinks.isEmpty else {
            logger.debug("No drinks to add or delete from HealthKit.")
            return
        }
        
        // Get a copy of the current drink data.
        // Actor-isolated property 'model' can not be referenced from synchronous context of global actor 'MainActor'
        // touching a stored propety ( model property )
        // Actor protects it's state and will not allow functions not an the actor access that state
        
        // guard let oldDrinks = model?.currentDrinks else { return }
        
        // Remove the deleted drinks.
        var drinks = currentDrinks.filter { deletedDrinks.contains($0.uuid) }
        
        // Add the new drinks.
        drinks += newDrinks
        
        // Sort the array by date.
        drinks.sort { $0.date < $1.date }
        // Actor-isolated property 'model' can not be referenced from synchronous context of global actor 'MainActor'
        currentDrinks = drinks
        
        await drinksUpdated()
    }
    
    // MARK: - Private Methods
    
    // The model's initializer. Do not call this method.
    // Use the shared instance instead.
    private init() {
        // Begin loading the data from disk.
        // this will cause issues better to make our model type a MainActor
        async { await load() }
    }
    
    // Begin loading the data from disk.
    func load() async {
        // Load data from I/O Actor
        var drinks = await store.load()
        // Drop old drinks
        drinks.removeOutdatedDrinks()
        
        // Assign loaded drinks to model
        currentDrinks = drinks
        
        // Load new data from HealthKit.
        // These do not touch any other parts of the actor state
        let success = await self.healthKitController.requestAuthorization()
            guard success else {
                logger.debug("Unable to authorize HealthKit.")
                return
            }
            
        await self.healthKitController.loadNewDataFromHealthKit()
    }
        
}

extension Array where Element == Drink {
    // Filter array to only the drinks in the last 24 hours.
    fileprivate mutating func removeOutdatedDrinks() {
        let endDate = Date()
        
        // The date and time 24 hours ago.
        let startDate = endDate.addingTimeInterval(-24.0 * 60.0 * 60.0)

        // The date range of drinks to keep
        let today = startDate...endDate
        
        // Return an array of drinks with a date parameter between
        // the start and end dates.
        self.removeAll { drink in
            !today.contains(drink.date)
        }
    }
}
