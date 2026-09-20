// DestinationEntity.swift
// An AppEntity representing a place Siri can navigate to, so
// "Set destination to <place> in Speedio" resolves the place BEFORE the
// intent runs — this is what makes the phrase donatable as an App Shortcut
// (plain String parameters cannot be used in App Shortcut phrases, which is
// why navigation previously fell through to Apple Maps).
//
// Resolution order:
//   1. Coordinates embedded in the id (from a fresh MapKit search) — precise.
//   2. The device's recent-search history ("recentSearches") — suggestions
//      when the driver says just "set destination" with no place.

import AppIntents
import Foundation
import MapKit

// MARK: - DestinationEntity

struct DestinationEntity: AppEntity {

    // MARK: AppEntity conformance

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(stringLiteral: "Destination")
    }

    // Nonisolated `static let` of an implicitly-Sendable query struct:
    // satisfies AppEntity's nonisolated `defaultQuery` requirement under
    // Swift 6 (a @MainActor stored static made the conformance cross into
    // main-actor-isolated code).
    static let defaultQuery = DestinationEntityQuery()

    /// Stable identity. For searched places the coordinates are embedded so
    /// the entity can be rebuilt into an MKMapItem without another network
    /// round trip: "33.4484,-112.0740|Phoenix". Recents use "recent|<title>".
    var id: String

    var name: String
    var address: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource
        if let address, !address.isEmpty {
            subtitle = LocalizedStringResource(stringLiteral: address)
        } else {
            subtitle = LocalizedStringResource(stringLiteral: "Destination")
        }
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: subtitle
        )
    }

    // MARK: Factory

    static func from(_ item: MKMapItem) -> DestinationEntity {
        let coordinate = item.placemark.coordinate
        let name = item.name ?? "Destination"
        let id = "\(coordinate.latitude),\(coordinate.longitude)|\(name)"
        return DestinationEntity(id: id, name: name, address: item.placemark.title)
    }

    /// Builds a fresh entity from the current search history for
    /// `suggestedEntities`.
    static func recent(id: String, title: String) -> DestinationEntity {
        DestinationEntity(id: id, name: title, address: nil)
    }

    /// Region-biased MapKit search through the shared view model so the
    /// request is biased to where the car is. `publishResults: false` keeps
    /// the phone-side published `searchResults` untouched — Siri resolution
    /// must never disturb what the in-app search UI is showing.
    /// MainActor-isolated because the shared view model is.
    ///
    /// Returns `DestinationEntity` (Sendable) rather than `[MKMapItem]`:
    /// MKMapItem is not Sendable, so returning it to the nonisolated entity
    /// query would cross the MainActor boundary with shared mutable state.
    /// Conversion to entities happens *inside* the actor.
    @MainActor
    static func search(_ query: String) async -> [DestinationEntity] {
        let items = await AppDelegate.sharedDriveViewModel.searchDestination(query: query, publishResults: false)
        return items.map(DestinationEntity.from)
    }

    // MARK: MKMapItem resolution

    /// Converts this entity back into an MKMapItem for the navigation
    /// pipeline: coordinates first (offline, precise), text search as the
    /// fallback for recents that never carried coordinates. The fallback
    /// search returns Sendable entities and the MKMapItem is rebuilt locally
    /// from the winning hit's embedded coordinates.
    func asMapItem() async -> MKMapItem? {
        if let coordinate = Self.coordinate(fromID: id) {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = name
            return item
        }
        let results = await Self.search(name)
        guard let first = results.first,
              let coordinate = Self.coordinate(fromID: first.id) else { return nil }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = first.name
        return item
    }

    /// Parses "lat,lon|…" out of the id. Returns nil for recents-style ids.
    static func coordinate(fromID id: String) -> CLLocationCoordinate2D? {
        let head = id.split(separator: "|", maxSplits: 1).first.map(String.init) ?? id
        let parts = head.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}

// MARK: - DestinationEntityQuery

/// Entity query Siri uses to resolve "set destination to <spoken place>"
/// into a DestinationEntity. Follows the same nonisolated-protocol /
/// MainActor-data pattern as `DriveSessionEntityQuery`.
struct DestinationEntityQuery: EntityStringQuery {

    // MARK: EntityStringQuery

    /// Spoken place -> MapKit POI/address search (region-biased to the
    /// driver's location by the shared view model).
    func entities(matching string: String) async throws -> [DestinationEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await suggestedEntities() }
        // `search` now returns Sendable entities (converted on the MainActor
        // inside), so nothing non-Sendable crosses back into this query.
        return await DestinationEntity.search(trimmed)
    }

    // MARK: EntityQuery

    /// Resolve stored ids. Only recents persist between sessions; searched
    /// entities are consumed immediately by the navigate intent.
    func entities(for identifiers: [String]) async throws -> [DestinationEntity] {
        let recents = Self.recentSearchEntities()
        return identifiers.compactMap { id in
            recents.first { $0.id == id }
        }
    }

    /// Siri's suggestions when the driver says "set destination" without a
    /// place: the most recent searches, most-relevant first.
    func suggestedEntities() async throws -> [DestinationEntity] {
        Self.recentSearchEntities()
    }

    // MARK: Helpers

    /// Recent searches (the same list the phone search bar shows) become
    /// suggested destinations.
    private static func recentSearchEntities() -> [DestinationEntity] {
        let titles = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
        return titles.prefix(5).map { title in
            DestinationEntity.recent(id: "recent|\(title)", title: title)
        }
    }
}
