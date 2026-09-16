// CarPlayNavigationManager.swift
// Manages full turn-by-turn navigation within CarPlay.
// Handles search, route calculation, guidance, and rerouting.

import AVFoundation
import Combine
import CarPlay
import MapKit
import Foundation

@MainActor
public class CarPlayNavigationManager: NSObject, NavigationActionDelegate {
    
    private let viewModel: DriveViewModel
    private let mapTemplate: CPMapTemplate
    private var navigationSession: CPNavigationSession?
    private var currentTrip: CPTrip?
    private var currentManeuver: CPManeuver?
    
    // NOTE: Removed local AVSpeechSynthesizer — all announcements go through
    // DriveViewModel.announce() to avoid two synthesizers competing/overlapping.
    private var isMuted: Bool = false
    
    private var currentSteps: [MKRoute.Step] = []
    private var currentStepIndex: Int = 0
    private var locationCancellable: AnyCancellable?
    private var estimateCancellable: AnyCancellable?
    /// Invalidates progress callbacks from a replaced CarPlay session.
    private var navigationGeneration: UInt64 = 0
    private var lastMatchedRemainingDistance: CLLocationDistance = 0

    // ── Session without navigation (idle CarPlay driving surface) ────
    //
    // Apple renders a map template with bare map buttons until the app
    // calls `startNavigationSession(for:)`, and Speedio only called that
    // once a real route was running. A driver who connected to CarPlay
    // without picking a destination therefore stared at an empty map:
    // speed/limit lived on the phone HUD, and the only way to surface
    // anything in the head unit's guidance chrome was turn-by-turn.
    //
    // `beginSessionWithoutNavigation()` starts a lightweight
    // CPNavigationSession at connect time — a zero-length placeholder
    // trip, no real route — and renders the shared DriveViewModel's live
    // speed/limit/road state into the session's maneuver card. That is
    // the CarPlay-native way to run a session without navigation. A real
    // trip replaces it through `endIdleSession(forNavigationTransition:)`;
    // the stop-echo latch armed there keeps CarPlay's delayed
    // `mapTemplateDidStopNavigating` callback (which carries no session
    // identity — see the reroute note above) from being mistaken for the
    // driver stopping the brand-new navigation.
    private var idleSession: CPNavigationSession?
    private var idleTrip: CPTrip?
    private var idleStateCancellable: AnyCancellable?
    private var lastIdleManeuverText: String?
    private var lastIdleManeuverSymbol: String?
    /// Until this instant, `mapTemplateDidStopNavigating` callbacks are the
    /// echo of the placeholder session's programmatic finishTrip — not the
    /// driver pressing Stop. Time-boxed because the echo is best-effort:
    /// when it never arrives the latch must expire on its own, and the
    /// callback alone cannot be attributed to a session.
    private var idleStopEchoGuardUntil: Date?

    public init(viewModel: DriveViewModel, mapTemplate: CPMapTemplate) {
        self.viewModel = viewModel
        self.mapTemplate = mapTemplate
        super.init()
        self.viewModel.navigationDelegate = self
        // CRITICAL: the navigation loop now lives in NavigationCoordinator
        // (extracted from DriveViewModel), and the COORDINATOR has its own
        // `navigationDelegate` used for startNavigationTrigger /
        // endNavigationTrigger / prepareForRouteTransition. If it is not
        // wired here, CarPlay navigation silently does nothing — the head
        // unit never receives the start trigger, so startNavigationSession
        // is never called and turn-by-turn never begins.
        self.viewModel.navigationCoordinator.navigationDelegate = self
        // The coordinator owns the single traffic-aware ETA source for both
        // phone and CarPlay. Push changes immediately instead of waiting for
        // the next CarPlay GPS callback, especially after a 90-second traffic
        // refresh completes while the head unit is rendering.
        estimateCancellable = viewModel.navigationCoordinator.$eta
            .combineLatest(viewModel.navigationCoordinator.$distanceToDestination)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, distance in
                guard let self, self.navigationSession != nil else { return }
                let fallback = self.viewModel.navigationCoordinator.proportionalRemainingTravelTime
                let time = self.viewModel.navigationCoordinator.trafficAwareRemainingTime(
                    forRemainingDistance: distance,
                    fallback: fallback
                )
                self.updateTripEstimates(distanceRemaining: distance, timeRemaining: time)
                if let maneuver = self.currentManeuver {
                    let maneuverDistance = max(0, self.viewModel.navigationCoordinator.distanceToNextTurn)
                    let route = self.viewModel.navigationCoordinator.currentRoute
                    let routeDistance = route?.distance ?? 0
                    let maneuverFallback = routeDistance > 0
                        ? (route?.expectedTravelTime ?? fallback) * min(1, maneuverDistance / routeDistance)
                        : (route?.expectedTravelTime ?? fallback)
                    let maneuverTime = self.viewModel.navigationCoordinator.trafficAwareRemainingTime(
                        forRemainingDistance: maneuverDistance,
                        fallback: maneuverFallback
                    )
                    self.navigationSession?.updateEstimates(
                        CPTravelEstimates(
                            distanceRemaining: SpeedFormatting.navigationDistanceMeasurement(
                                forMeters: maneuverDistance,
                                measurementSystem: SpeedFormatting.measurementSystem()
                            ),
                            timeRemaining: max(1, maneuverTime)
                        ),
                        for: maneuver
                    )
                }
            }
    }
    
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }
    
    public func getMuted() -> Bool {
        return self.isMuted
    }

    /// Clean up the active CPNavigationSession without ending phone-side
    /// navigation. Called by CarPlaySceneDelegate when the user disconnects
    /// from CarPlay so the system framework doesn't leak the session.
    public func finishCurrentSession() {
        navigationGeneration &+= 1
        locationCancellable?.cancel()
        locationCancellable = nil
        // Disconnect also tears down the placeholder session — leaving it
        // running would leak the CPNavigationSession into the framework.
        endIdleSession(forNavigationTransition: false)
        navigationSession?.finishTrip()
        navigationSession = nil
        currentManeuver = nil
        lastMatchedRemainingDistance = 0
    }

    /// Defensive cleanup in case `finishCurrentSession()` was not called
    /// before deallocation (crash path, unexpected teardown order).
    deinit {
        estimateCancellable?.cancel()
        idleStateCancellable?.cancel()
        idleSession?.finishTrip()
        navigationSession?.finishTrip()
    }

    // MARK: - Session Without Navigation

    /// Starts the placeholder CPNavigationSession that surfaces the live
    /// speed/limit banner before — and without — any turn-by-turn route.
    /// No-ops while real navigation is active or a placeholder already runs.
    public func beginSessionWithoutNavigation() {
        guard !viewModel.isNavigating, idleSession == nil else { return }

        let routeChoice = CPRouteChoice(
            summaryVariants: ["Drive"],
            additionalInformationVariants: ["Live speed and limit"],
            selectionSummaryVariants: ["Drive"])
        // Both ends point at the vehicle: this trip is a UI surface for the
        // speed banner, not a routable request. It is finished — never
        // guided — the moment a real trip starts or CarPlay disconnects.
        let here = MKMapItem.forCurrentLocation()
        let trip = CPTrip(origin: here, destination: here, routeChoices: [routeChoice])
        idleTrip = trip
        idleSession = mapTemplate.startNavigationSession(for: trip)
        // The estimates panel intentionally reads zero: there is no route,
        // so there is no remaining distance or time to show.
        mapTemplate.updateEstimates(
            CPTravelEstimates(
                distanceRemaining: Measurement(value: 0, unit: UnitLength.meters),
                timeRemaining: 0),
            for: trip)

        idleStateCancellable = viewModel.$speed
            .combineLatest(viewModel.$limit, viewModel.$status, viewModel.$currentRoadName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshIdleManeuverCard()
            }
        refreshIdleManeuverCard()
    }

    /// Renders the current speed sentence into the placeholder session's
    /// maneuver card (the head unit's guidance banner). The update is skipped
    /// entirely when nothing the card shows changed, so a stationary car with
    /// a steady limit costs no CarPlay IPC at all.
    private func refreshIdleManeuverCard() {
        guard idleSession != nil else { return }
        let system = SpeedFormatting.measurementSystem()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: system)
        let displayLimit = SpeedFormatting.displayLimit(
            forMph: viewModel.limit, measurementSystem: system)

        var summary = "\(Int(viewModel.speed)) \(unitShort)"
        if displayLimit > 0 { summary += " · Limit \(displayLimit)" }
        if let road = viewModel.currentRoadName, !road.isEmpty { summary += " · \(road)" }

        // The banner mirrors the same status colors the alert engine uses.
        // Overspeed additionally raises the full CPNavigationAlert through
        // CarPlayNavigationRootTemplate.handleAlerts, which overlays this
        // card — the icon here only has to survive the in-between states.
        let symbol: String
        switch viewModel.status {
        case .over:    symbol = "exclamationmark.octagon.fill"
        case .warning: symbol = "exclamationmark.triangle.fill"
        case .safe:    symbol = "speedometer"
        }

        guard summary != lastIdleManeuverText || symbol != lastIdleManeuverSymbol else { return }
        lastIdleManeuverText = summary
        lastIdleManeuverSymbol = symbol

        let maneuver = CPManeuver()
        maneuver.instructionVariants = [summary]
        if let icon = UIImage(systemName: symbol) {
            maneuver.symbolImage = icon
        }
        idleSession?.upcomingManeuvers = [maneuver]
    }

    /// Finishes the placeholder session. `forNavigationTransition: true` is
    /// used when a real trip is taking over: the programmatic finishTrip can
    /// make CarPlay echo `mapTemplateDidStopNavigating` with no session
    /// identity, and the time-boxed latch keeps that echo from cancelling the
    /// navigation that is starting right now.
    public func endIdleSession(forNavigationTransition: Bool) {
        let hadSession = idleSession != nil
        idleSession?.finishTrip()
        releaseIdleSessionIfPresent()
        idleStopEchoGuardUntil = (forNavigationTransition && hadSession)
            ? Date().addingTimeInterval(Self.idleStopEchoGuardWindow)
            : nil
    }

    /// Releases the placeholder-session bindings after the framework ended
    /// the session on its own (driver tapped End on the head unit, or the
    /// framework recycled it during a preview). No-op when the placeholder
    /// was already replaced or torn down.
    ///
    /// Deliberately does NOT touch `idleStopEchoGuardUntil`: the latch
    /// belongs to the navigation transition, not to the session bindings,
    /// and the stop-callback handler must be able to release stale bindings
    /// BEFORE consulting the latch without erasing it.
    public func releaseIdleSessionIfPresent() {
        idleStateCancellable?.cancel()
        idleStateCancellable = nil
        idleSession = nil
        idleTrip = nil
        lastIdleManeuverText = nil
        lastIdleManeuverSymbol = nil
    }

    /// True while `mapTemplateDidStopNavigating` should be treated as the
    /// echo of a just-finished placeholder session rather than a driver stop.
    public func isIdleStopEchoGuardActive(now: Date = Date()) -> Bool {
        guard let until = idleStopEchoGuardUntil else { return false }
        if now >= until {
            idleStopEchoGuardUntil = nil
            return false
        }
        return true
    }

    /// See `idleStopEchoGuardUntil`. Short by design: the echo, when it
    /// exists at all, arrives within a couple of seconds on every supported
    /// head unit, and a long window could swallow a real driver stop that
    /// immediately follows a navigation start.
    static let idleStopEchoGuardWindow: TimeInterval = 3

    /// Invalidates the old progress stream before NavigationCoordinator
    /// publishes a replacement leg. Keep the CPNavigationSession alive: the
    /// CPMapTemplate stop callback has no session identity, so finishing the
    /// old session here could make a delayed callback look like a real user
    /// stop on the replacement session.
    public func prepareForRouteTransition() {
        navigationGeneration &+= 1
        locationCancellable?.cancel()
        locationCancellable = nil
        navigationSession?.upcomingManeuvers = []
        currentManeuver = nil
        lastMatchedRemainingDistance = 0
    }
    
    public func searchDestination(query: String, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let coordinate = viewModel.locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D()
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        // No pointOfInterestFilter — the driver picks from ANY category
        // (gas, coffee, hospital, hotel, EV charger, grocery, etc.), not
        // just a fixed subset. The query text drives what comes back.

        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            // Rank POIs above plain addresses so the CarPlay rows lead with
            // the same places the phone's Apple Maps shows for the query
            // (TestFlight 2.3.0 b653).
            completion(Array(Self.poiFirst(Array(response?.mapItems ?? [])).prefix(10)))
        }
    }
    
    public func startNavigation(to destination: MKMapItem) {
        Task {
            do {
                let route = try await calculateRoute(to: destination)
                self.startNavigation(route: route, destination: destination)
            } catch {
                print("Failed to calculate route: \(error)")
            }
        }
    }
    
    public func searchDestinationTrigger(_ query: String) async -> [MKMapItem] {
        return await searchDestination(query: query, near: viewModel.locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D())
    }
    
    public func startNavigationTrigger(to destination: MKMapItem, route: MKRoute?) async {
        if let providedRoute = route {
            startNavigation(route: providedRoute, destination: destination)
        } else {
            do {
                let route = try await calculateRoute(to: destination)
                startNavigation(route: route, destination: destination)
            } catch {
                print("Failed to calculate route: \(error)")
            }
        }
    }
    
    public func endNavigationTrigger() async {
        // NavigationCoordinator clears its route before calling this delegate.
        // If a new route was started while the old async delegate hop was
        // suspended, do not let the stale completion tear down that new
        // CarPlay session.
        guard !viewModel.isNavigating,
              viewModel.navigationCoordinator.currentRoute == nil else { return }
        endNavigation()
        // Navigation ended while CarPlay is still connected (arrival, or the
        // driver stopped guidance from the phone). Restore the "session
        // without navigation" surface so the head unit keeps showing the
        // live speed/limit banner for the rest of the drive. Deliberately
        // NOT called from endNavigation() itself: the startedTrip route
        // replacement also runs endNavigation() mid-handoff, and resurrecting
        // the placeholder there would race the trip that is starting.
        beginSessionWithoutNavigation()
    }
    
    // MARK: - Search
    public func searchDestination(query: String, near coordinate: CLLocationCoordinate2D) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // 50km radius
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        request.region = region
        
        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            // POI-first ranking — see poiFirst(_:).
            return Array(Self.poiFirst(response.mapItems).prefix(5))
        } catch {
            print("Search error: \(error)")
            return []
        }
    }
    
    // MARK: - Search result ranking

    /// Ranks points of interest above plain addresses, mirroring the phone's
    /// Apple Maps app. Raw MKLocalSearch puts an exact street-address match
    /// (often the very road the car is parked on) at the top of the response,
    /// so the CarPlay keyboard rows filled with "S Tumbleweed Ln" while the
    /// phone showed Tumbleweed Park, the Recreation Center, and the Pickleball
    /// Courts for the same query (TestFlight 2.3.0 b653). The POIs are already
    /// in the same response — this only re-orders, with no extra request and
    /// no dropped results. The sort is stable: ties keep MapKit's relevance
    /// order.
    ///
    /// 0 = POI, 1 = other, 2 = plain address (name is the formatted address).
    nonisolated private static func poiFirstOrderingKey(_ item: MKMapItem) -> Int {
        if item.pointOfInterestCategory != nil { return 0 }
        let isAddress = item.name != nil && item.name == item.placemark.title
        return isAddress ? 2 : 1
    }

    /// Stable-sorts map items so POIs lead and plain formatted addresses trail.
    nonisolated static func poiFirst(_ items: [MKMapItem]) -> [MKMapItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                let l = poiFirstOrderingKey(lhs.element)
                let r = poiFirstOrderingKey(rhs.element)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map { $0.element }
    }

    // MARK: - Route Calculation

    /// Calculates up to three alternate routes (fastest first) for the
    /// CarPlay trip preview so the driver can pick between them, like
    /// Google Maps. Falls back to a single route if alternates fail.
    public func calculateRoutes(to destination: MKMapItem, completion: @escaping ([MKRoute]) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.departureDate = .now

        if UserDefaults.standard.bool(forKey: "avoidHighways") {
            request.highwayPreference = .avoid
        }

        let directions = MKDirections(request: request)
        directions.calculate { response, _ in
            let routes = Array((response?.routes ?? []).prefix(3))
            completion(routes)
        }
    }

    public func calculateRoute(to destination: MKMapItem) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.departureDate = .now // Real-time traffic awareness
        
        let avoidHighways = UserDefaults.standard.bool(forKey: "avoidHighways")
        if avoidHighways {
            request.highwayPreference = .avoid
        }
        
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        
        guard let fastest = response.routes.first else {
            throw NSError(domain: "Navigation", code: 404, userInfo: [NSLocalizedDescriptionKey: "No routes found"])
        }
        
        return fastest
    }
    
    // MARK: - Navigation Control
    public func startNavigation(route: MKRoute, destination: MKMapItem) {
        // A placeholder session-without-navigation must make way for the real
        // trip: finish it here, before the new session starts, so the template
        // never runs two sessions at once. The transition also arms the stop-
        // echo latch (see endIdleSession) so the finish's delayed callback
        // cannot look like the driver stopping the brand-new navigation.
        endIdleSession(forNavigationTransition: true)
        // Reroutes and multi-stop leg transitions reuse the active CarPlay
        // session. A CPMapTemplate stop callback has no session identity, so
        // finishing and immediately recreating the session can make a delayed
        // old callback end the phone's new directions. Keep the session and
        // replace its maneuver stream instead.
        navigationGeneration &+= 1
        locationCancellable?.cancel()
        locationCancellable = nil
        navigationSession?.upcomingManeuvers = []
        currentManeuver = nil
        // A replacement route has a new geometry. Never carry a lower
        // remaining-distance snapshot from the previous route into it.
        lastMatchedRemainingDistance = route.distance

        viewModel.isNavigating = true
        viewModel.navigationCoordinator.currentRoute = route
        // Only intermediate stops make this a multi-stop session. A normal
        // route calculation may still leave a single RouteLeg snapshot behind.
        let hasMultiStopState = !viewModel.routeStops.isEmpty
        if !hasMultiStopState {
            // For a normal route this is the final destination. During a
            // multi-stop route the coordinator keeps `destination` as the
            // final endpoint while this call receives the active stop.
            viewModel.navigationCoordinator.destination = destination
        }

        // For a normal route this is the complete trip. For a multi-stop
        // route, NavigationCoordinator has already published the remaining
        // total (and updates it at each stop); do not shrink Siri/HUD values
        // back to the current leg while replacing the CarPlay session.
        if !hasMultiStopState {
            let estimatedTime = route.expectedTravelTime
            viewModel.navigationCoordinator.eta = Date().addingTimeInterval(estimatedTime)
            // Mirror CarPlay's remaining-route distance onto the ViewModel
            // right away so Siri can answer before the next progress tick.
            viewModel.navigationCoordinator.distanceToDestination = route.distance
        }
        
        let routeChoice = CPRouteChoice(
            summaryVariants: ["Fastest Route"],
            additionalInformationVariants: [],
            selectionSummaryVariants: ["Fastest"]
        )
        // Keep the CPTrip destination stable at the final endpoint. The
        // CPNavigationSession's trip is immutable; using the active stop here
        // would leave stale stop metadata after a route transition because
        // the existing session is intentionally reused to avoid an ambiguous
        // delayed stop callback. The maneuver stream below still follows the
        // active leg and the phone coordinator owns the complete stop plan.
        let tripDestination = viewModel.navigationCoordinator.destination ?? destination
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: tripDestination, routeChoices: [routeChoice])
        
        if navigationSession == nil {
            self.currentTrip = trip
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }

        currentSteps = route.steps

        // Initialize the overall CarPlay banner before the first location
        // callback. Without this, CarPlay keeps its own wall-clock/default
        // values (`8:08`, `0 min`, `-- mi`) until progress arrives. For a
        // multi-stop route, use the coordinator's already-published total,
        // not only the active leg.
        let initialDistance = hasMultiStopState
            ? viewModel.navigationCoordinator.distanceToDestination
            : route.distance
        let initialTime = hasMultiStopState
            ? max(0, viewModel.navigationCoordinator.eta?.timeIntervalSinceNow ?? route.expectedTravelTime)
            : route.expectedTravelTime
        updateTripEstimates(
            distanceRemaining: initialDistance > 0 ? initialDistance : route.distance,
            timeRemaining: initialTime
        )
        
        // Skip initial steps with 0 distance (usually just the starting point)
        currentStepIndex = 0
        while currentStepIndex < currentSteps.count && currentSteps[currentStepIndex].distance <= 0 {
            currentStepIndex += 1
        }
        
        // If we skipped everything, reset to 0
        if currentStepIndex >= currentSteps.count {
            currentStepIndex = 0
        }
        
        monitorProgress()
        // NOTE: Do NOT call announce() here — DriveViewModel.startNavigation(with:) handles
        // the initial voice announcement to avoid duplicate "starting navigation" speech.
        advanceToNextStep()
    }
    
    /// Adopts a navigation session that CarPlay started internally (e.g.
    /// after the user accepted a session-restoration prompt or tapped "Start"
    /// on a trip preview). Calculates our own route and runs through the full
    /// coordinator flow so speed HUD, turn-by-turn, and drive recording all
    /// reflect the active trip. CarPlay's `CPMapTemplateDelegate.startedTrip`
    /// fires before this method is called; `startNavigationSession(for:)`
    /// (called by `startNavigation`) installs the app-managed session when
    /// CarPlay has not already provided one, so the existing session remains
    /// the single source of CarPlay navigation callbacks.
    public func handleCarPlayStartedTrip(_ trip: CPTrip) async {
        let destination = trip.destination

        do {
            let route = try await calculateRoute(to: destination)
            // Set destination on the coordinator *before* calling
            // startNavigation(with:) so the delegate chain fires correctly.
            // The coordinator reads self.destination inside startNavigation
            // to pass it through to startNavigationTrigger.
            viewModel.navigationCoordinator.destination = destination
            viewModel.navigationCoordinator.destinationItem = destination
            // Run through the full coordinator pipeline: it resets step flags,
            // starts the reroute timer, sets ETA/distance, auto-starts session
            // recording, caches route segments, starts Live Activity, speaks
            // the initial announcement, and calls back to our
            // `startNavigation(route:destination:)` via the delegate chain.
            await viewModel.navigationCoordinator.startNavigation(with: route)
        } catch {
            print("handleCarPlayStartedTrip: Failed to calculate route: \(error)")
        }
    }

    public func endNavigation() {
        navigationGeneration &+= 1
        endIdleSession(forNavigationTransition: false)
        navigationSession?.finishTrip()
        navigationSession = nil
        currentTrip = nil
        currentManeuver = nil
        locationCancellable?.cancel()
        lastMatchedRemainingDistance = 0

        viewModel.isNavigating = false
        viewModel.navigationCoordinator.currentRoute = nil
        viewModel.navigationCoordinator.destination = nil
        viewModel.navigationCoordinator.nextManeuverInstruction = ""
        viewModel.navigationCoordinator.distanceToNextTurn = 0
        viewModel.navigationCoordinator.distanceToDestination = 0
        viewModel.navigationCoordinator.eta = nil
    }
    
    private func monitorProgress() {
        let generation = navigationGeneration
        locationCancellable = viewModel.locationManager.$latestLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.evaluateNavigationProgress(at: location, generation: generation)
            }
    }
    
    private func evaluateNavigationProgress(at location: CLLocation, generation: UInt64) {
        guard generation == navigationGeneration else { return }
        guard let currentRoute = viewModel.navigationCoordinator.currentRoute, let session = navigationSession else { return }

        // 1. Check distance to next turn (step)
        if currentStepIndex < currentSteps.count {
            let nextStep = currentSteps[currentStepIndex]
            let stepStart = CLLocation(latitude: nextStep.polyline.coordinate.latitude,
                                       longitude: nextStep.polyline.coordinate.longitude)

            let distance = location.distance(from: stepStart)
            viewModel.navigationCoordinator.distanceToNextTurn = distance

            // Advance step if within 15 meters
            if distance < 15.0 {
                currentStepIndex += 1
                advanceToNextStep()
            }
        }
        // Arrival and intermediate-stop transitions are owned by
        // NavigationCoordinator, which receives the same location heartbeat
        // and knows the active leg. Do not independently compare against the
        // final destination here: during a multi-stop route that destination
        // is intentionally farther away than the active CarPlay trip.

        // ── ETA Estimation ───────────────────────────────────────────
        //
        // PROBLEM: The old formula used a proportional estimate based on
        // step-index position:
        //   remainingDist = route.distance - steps[0..<currentStepIndex]
        //   timeRemaining = expectedTravelTime × (remainingDist / totalDist)
        //
        // This had two flaws:
        //   1. Step-index LAG — the index only advances when the user is
        //      within 15 m of the NEXT step's start coordinate, so
        //      "completed" distance lags actual travel by potentially
        //      several kilometers, inflating remainingDist.
        //   2. No SPEED FEEDBACK — the proportion never adjusts for
        //      actual driving speed, so a user on an open highway sees
        //      the same ETA as if they were stuck in traffic.
        //
        // FIX: Scan the route polyline to find where the user actually is
        // (matching to the nearest segment, not step-index), compute the
        // remaining distance along the polyline, and use location.speed
        // (CoreLocation-smoothed with an exponential moving average) for
        // a real-time speed-based estimate that converges within seconds.

        let measuredRemainingDistance = actualRemainingDistance(route: currentRoute, location: location)
        let locallyMatchedDistance = lastMatchedRemainingDistance > 0
            ? min(measuredRemainingDistance, lastMatchedRemainingDistance)
            : measuredRemainingDistance
        // NavigationCoordinator receives the same GPS stream and is the
        // canonical phone + CarPlay distance publisher. Only use the local
        // match as a cold-start fallback while that publisher has not emitted.
        let coordinatorDistance = viewModel.navigationCoordinator.distanceToDestination
        var remainingDist = coordinatorDistance > 0 ? coordinatorDistance : locallyMatchedDistance
        lastMatchedRemainingDistance = locallyMatchedDistance

        // Apple's traffic-aware route estimate is the source of truth. Do
        // not replace it with instantaneous GPS speed while stopped or in
        // noisy urban GPS conditions.
        let activeLegDistance = coordinatorDistance > 0
            ? min(coordinatorDistance, currentRoute.distance)
            : min(remainingDist, currentRoute.distance)
        var expectedRemainingTime = currentRoute.expectedTravelTime *
            min(1.0, max(0.0, activeLegDistance / max(currentRoute.distance, 1)))
        // The active CarPlay leg is only part of a multi-stop journey.
        // Include every later leg in the lower ETA/distance banner so it
        // cannot collapse to the next stop's small route or show zero.
        if !viewModel.routeStops.isEmpty {
            let activeLegIndex = viewModel.navigationCoordinator.activeMultiStopLegIndexForDisplay
            if activeLegIndex + 1 < viewModel.routeLegs.count {
                let laterLegs = viewModel.routeLegs[(activeLegIndex + 1)...]
                remainingDist += laterLegs.reduce(0) { $0 + $1.distance }
                expectedRemainingTime += laterLegs.reduce(0) { $0 + $1.travelTime }
            }
        }
        let proportionalEstimate = max(0, expectedRemainingTime)
        let timeRemaining = viewModel.navigationCoordinator.trafficAwareRemainingTime(
            forRemainingDistance: remainingDist,
            fallback: proportionalEstimate
        )

        // The coordinator already publishes this canonical distance to Siri
        // and the phone HUD. CarPlay only renders the same value here.
        updateTripEstimates(distanceRemaining: remainingDist, timeRemaining: timeRemaining)
        
        if let maneuver = currentManeuver {
            // The active maneuver gets the next-turn estimate.
            let maneuverDistance = max(0, viewModel.navigationCoordinator.distanceToNextTurn)
            let maneuverMeasurement = SpeedFormatting.navigationDistanceMeasurement(
                forMeters: maneuverDistance,
                measurementSystem: SpeedFormatting.measurementSystem()
            )
            let maneuverFallback = currentRoute.distance > 0
                ? currentRoute.expectedTravelTime * min(1, maneuverDistance / currentRoute.distance)
                : currentRoute.expectedTravelTime
            let maneuverTime = viewModel.navigationCoordinator.trafficAwareRemainingTime(
                forRemainingDistance: maneuverDistance,
                fallback: maneuverFallback
            )
            session.updateEstimates(
                CPTravelEstimates(distanceRemaining: maneuverMeasurement,
                                  timeRemaining: max(1, maneuverTime)),
                for: maneuver
            )
        }
    }

    /// Updates the overall ETA/distance banner for the active trip. Unlike
    /// `CPNavigationSession.updateEstimates`, this is trip-scoped and belongs
    /// to the map template.
    private func updateTripEstimates(distanceRemaining: CLLocationDistance,
                                     timeRemaining: TimeInterval) {
        guard let trip = currentTrip else { return }
        let measurement = SpeedFormatting.navigationDistanceMeasurement(
            forMeters: max(0, distanceRemaining),
            measurementSystem: SpeedFormatting.measurementSystem()
        )
        let estimates = CPTravelEstimates(
            distanceRemaining: measurement,
            timeRemaining: max(0, timeRemaining)
        )
        mapTemplate.updateEstimates(estimates, for: trip)
    }

    /// Walks the route polyline to find where `location` actually sits on
    /// the path (nearest-segment matching, not step-index-based) and
    /// returns the remaining distance in meters from that point to the
    /// destination. This eliminates the step-index lag that caused the
    /// old proportional ETA to overstate remaining distance by several km.
    private func actualRemainingDistance(route: MKRoute, location: CLLocation) -> CLLocationDistance {
        let polyline = route.polyline
        let points = polyline.points()
        let count = polyline.pointCount
        guard count > 0 else { return route.distance }

        let userCoord = location.coordinate
        var minDist = CLLocationDistance.infinity
        var cumulativeDist: CLLocationDistance = 0
        var bestDistAlong: CLLocationDistance = route.distance

        for i in 0..<(count - 1) {
            let p1 = points[i].coordinate
            let p2 = points[i + 1].coordinate

            let segLen = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))

            let nearest = nearestPointOnSegment(userCoord: userCoord, v: p1, w: p2)
            let dist = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))

            if dist < minDist {
                minDist = dist
                let distAlongSeg = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                    .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))
                bestDistAlong = cumulativeDist + distAlongSeg
            }

            cumulativeDist += segLen
        }

        return max(0, route.distance - bestDistAlong)
    }

    /// Clamps `userCoord` to the line segment `v→w` and returns the
    /// closest point on that segment. Used by `actualRemainingDistance`
    /// to pin the user to the exact route geometry.
    private func nearestPointOnSegment(userCoord: CLLocationCoordinate2D, v: CLLocationCoordinate2D, w: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let l2 = pow(v.longitude - w.longitude, 2) + pow(v.latitude - w.latitude, 2)
        if l2 == 0 { return v }
        var t = ((userCoord.longitude - v.longitude) * (w.longitude - v.longitude) + (userCoord.latitude - v.latitude) * (w.latitude - v.latitude)) / l2
        t = max(0, min(1, t))
        return CLLocationCoordinate2D(
            latitude: v.latitude + t * (w.latitude - v.latitude),
            longitude: v.longitude + t * (w.longitude - v.longitude)
        )
    }
    
    // Helper to sum distances up to index bounds safely
    private func advanceToNextStep() {
        guard currentStepIndex < currentSteps.count else { return }
        let maneuver = currentSteps[currentStepIndex]
        
        viewModel.navigationCoordinator.nextManeuverInstruction = maneuver.instructions
        viewModel.navigationCoordinator.nextManeuverImageName = symbolName(for: maneuver)
        
        let cpManeuver = CPManeuver()
        cpManeuver.instructionVariants = [maneuver.instructions]
        
        // Premium Icons for CarPlay
        if let icon = UIImage(systemName: symbolName(for: maneuver)) {
            cpManeuver.symbolImage = icon
        }
        let distanceMeasure = SpeedFormatting.navigationDistanceMeasurement(
            forMeters: maneuver.distance,
            measurementSystem: SpeedFormatting.measurementSystem()
        )
        let routeTime = viewModel.navigationCoordinator.currentRoute?.expectedTravelTime ?? 0
        let routeDistance = viewModel.navigationCoordinator.currentRoute?.distance ?? maneuver.distance
        let maneuverTime = max(1, routeTime * maneuver.distance / max(routeDistance, 1))
        cpManeuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: distanceMeasure,
            timeRemaining: maneuverTime
        )

        self.currentManeuver = cpManeuver
        navigationSession?.upcomingManeuvers = [cpManeuver]

        
        // Voice announcement goes through DriveViewModel's single synthesizer (avoids overlaps)
        // Only announce if the step has substance (distance > 0 and non-empty instructions)
        if maneuver.distance > 0 && !maneuver.instructions.isEmpty && !isMuted {
            // We directly call DriveViewModel's internal announce through the public path
            // by updating the shared instruction state — DriveViewModel's location handler
            // will call announce() at the right distance thresholds.
            // For CarPlay step transitions, we post a notification that DriveViewModel picks up.
        }
    }
    
    public func showManeuversList(interfaceController: CPInterfaceController?) {
        guard !currentSteps.isEmpty else { return }
        
        let listItems = currentSteps.enumerated().map { index, step in
            let distance = SpeedFormatting.navigationDistanceLabel(
                forMeters: step.distance,
                measurementSystem: SpeedFormatting.measurementSystem()
            )
            let item = CPListItem(text: step.instructions, detailText: distance)
            if let icon = UIImage(systemName: symbolName(for: step)) {
                item.setImage(icon)
            }
            // Highlight current step
            if index == currentStepIndex {
                item.accessoryType = .disclosureIndicator
            }
            return item
        }
        
        let listTemplate = CPListTemplate(title: "Route Overview", sections: [CPListSection(items: listItems, header: nil, sectionIndexTitle: nil)])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }
    
    private func symbolName(for step: MKRoute.Step) -> String {
        // Basic mapping of instructions to SF Symbols
        // U-turn MUST be checked before left/right
        let inst = step.instructions.lowercased()
        if inst.contains("u-turn") || inst.contains("u turn") || inst.contains("uturn") { return "arrow.uturn.left" }
        if inst.contains("left") { return "arrow.turn.up.left" }
        if inst.contains("right") { return "arrow.turn.up.right" }
        if inst.contains("exit") || inst.contains("take ramp") { return "arrow.up.right.circle" }
        if inst.contains("roundabout") { return "arrow.counterclockwise" }
        if inst.contains("destination") { return "mappin.and.ellipse" }
        return "arrow.up"
    }
}

