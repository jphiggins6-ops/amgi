//
//  DecksRequestsTests.swift
//  AnkiProtoBridgeTests
//
//  Created by Vladimir Gusev on 07.05.2026.
//

import Testing
import Foundation
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
private import SwiftProtobuf

@Suite struct DecksRequestsTests {
    // MARK: - setCurrentDeck (Void) / renameDeck / removeDecks (CollectionChanges)

    @Test func setCurrentDeck_dispatches_and_encodes_deckId() throws {
        let envelope: Request<Void> = .setCurrentDeck(deckId: DeckID(42))
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.setCurrentDeck)
        let proto = try Anki_Decks_DeckId(serializedBytes: envelope.body)
        #expect(proto.did == 42)
    }

    @Test func renameDeck_dispatches_and_encodes_fields() throws {
        let envelope: Request<CollectionChanges> = .renameDeck(deckId: DeckID(7), newName: "Korean::Verbs")
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.renameDeck)
        let proto = try Anki_Decks_RenameDeckRequest(serializedBytes: envelope.body)
        #expect(proto.deckID == 7)
        #expect(proto.newName == "Korean::Verbs")
    }

    @Test func renameDeck_decodes_OpChanges_into_CollectionChanges() throws {
        var opChanges = Anki_Collection_OpChanges()
        opChanges.deck = true
        opChanges.studyQueues = true
        let bytes = try opChanges.serializedData()

        let envelope: Request<CollectionChanges> = .renameDeck(deckId: DeckID(7), newName: "Korean::Verbs")
        #expect(try envelope.decode(bytes) == CollectionChanges(deck: true, studyQueues: true))
    }

    @Test func removeDecks_dispatches_and_encodes_id_list() throws {
        let envelope: Request<CollectionChanges> = .removeDecks(deckIds: [DeckID(1), DeckID(2), DeckID(3)])
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.removeDecks)
        let proto = try Anki_Decks_DeckIds(serializedBytes: envelope.body)
        #expect(proto.dids == [1, 2, 3])
    }

    @Test func removeDecks_decodes_OpChangesWithCount_into_CollectionChanges() throws {
        var resp = Anki_Collection_OpChangesWithCount()
        resp.changes.deck = true
        resp.changes.card = true
        let bytes = try resp.serializedData()

        let envelope: Request<CollectionChanges> = .removeDecks(deckIds: [DeckID(1)])
        #expect(try envelope.decode(bytes) == CollectionChanges(card: true, deck: true))
    }

    // MARK: - getCurrentDeck

    @Test func getCurrentDeck_dispatches_with_empty_body() throws {
        let envelope: Request<DeckInfo> = .getCurrentDeck
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.getCurrentDeck)
        #expect(try envelope.body.isEmpty)
    }

    @Test func getCurrentDeck_decodes_into_DeckInfo() throws {
        var deck = Anki_Decks_Deck()
        deck.id = 100
        deck.name = "Korean"
        let bytes = try deck.serializedData()
        let envelope: Request<DeckInfo> = .getCurrentDeck
        let info = try envelope.decode(bytes)
        #expect(info.id == DeckID(100))
        #expect(info.name == "Korean")
    }

    // MARK: - newDeck / addDeck (two-phase)

    @Test func newDeck_dispatches_with_empty_body() throws {
        let envelope: Request<DeckTemplate> = .newDeck
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.newDeck)
        #expect(try envelope.body.isEmpty)
    }

    @Test func newDeck_decodes_bytes_into_opaque_template() throws {
        var deck = Anki_Decks_Deck()
        deck.id = 0
        deck.name = ""
        let bytes = try deck.serializedData()
        let envelope: Request<DeckTemplate> = .newDeck
        let template = try envelope.decode(bytes)
        // Round-trip preserves the original byte payload.
        #expect(template.bytes == bytes)
    }

    @Test func addDeck_renames_template_and_encodes_for_addDeck() throws {
        var deck = Anki_Decks_Deck()
        deck.id = 0
        deck.name = "default-name"
        let templateBytes = try deck.serializedData()
        let template = DeckTemplate(bytes: templateBytes)

        let envelope: Request<DeckCreation> = .addDeck(template: template, name: "Korean")
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.addDeck)
        let proto = try Anki_Decks_Deck(serializedBytes: envelope.body)
        #expect(proto.name == "Korean")
    }

    @Test func addDeck_decodes_OpChangesWithId_into_DeckCreation() throws {
        var resp = Anki_Collection_OpChangesWithId()
        resp.id = 12345
        resp.changes.deck = true
        let bytes = try resp.serializedData()

        let template = DeckTemplate(bytes: Data())
        let envelope: Request<DeckCreation> = .addDeck(template: template, name: "x")
        let decoded = try envelope.decode(bytes)
        #expect(decoded.id == DeckID(12345))
        #expect(decoded.changes == CollectionChanges(deck: true))
    }

    // MARK: - existing deckNames coverage

    @Test func deckNames_dispatches_to_decks_service_getDeckNames_method() {
        let request: Request<[DeckInfo]> = .deckNames
        #expect(request.serviceId == ServiceID.decks)
        #expect(request.methodId == DecksMethod.getDeckNames)
    }

    @Test func deckNames_decode_maps_proto_entries_to_DeckInfo_with_typed_ids() throws {
        var proto = Anki_Decks_DeckNames()
        var first = Anki_Decks_DeckNameId()
        first.id = 42
        first.name = "Default"
        var second = Anki_Decks_DeckNameId()
        second.id = 100
        second.name = "Korean"
        proto.entries = [first, second]

        let bytes = try proto.serializedData()
        let request: Request<[DeckInfo]> = .deckNames
        let decoded = try request.decode(bytes)

        #expect(decoded.count == 2)
        #expect(decoded[0].id == DeckID(42))
        #expect(decoded[0].name == "Default")
        #expect(decoded[1].id == DeckID(100))
        #expect(decoded[1].name == "Korean")
    }

    // MARK: - deckTree

    @Test func deckTree_dispatches_to_decks_service_getDeckTree_method() {
        let request: Request<[DeckTreeNode]> = .deckTree()
        #expect(request.serviceId == ServiceID.decks)
        #expect(request.methodId == DecksMethod.getDeckTree)
    }

    @Test func deckTree_encodes_now_timestamp_in_body() throws {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let request: Request<[DeckTreeNode]> = .deckTree(at: instant)
        let body = try Anki_Decks_DeckTreeRequest(serializedBytes: request.body)
        #expect(body.now == 1_700_000_000)
    }

    @Test func deckTree_drops_synthetic_root_and_joins_full_paths() throws {
        // Synthetic root with one top-level deck "Korean" containing "Vocab".
        var vocab = Anki_Decks_DeckTreeNode()
        vocab.deckID = 200
        vocab.name = "Vocab"
        vocab.newCount = 4
        vocab.learnCount = 1
        vocab.reviewCount = 7

        var korean = Anki_Decks_DeckTreeNode()
        korean.deckID = 100
        korean.name = "Korean"
        korean.children = [vocab]

        var root = Anki_Decks_DeckTreeNode()
        root.deckID = 0
        root.children = [korean]

        let bytes = try root.serializedData()
        let decoded = try Request<[DeckTreeNode]>.deckTree().decode(bytes)

        #expect(decoded.count == 1)
        let top = try #require(decoded.first)
        #expect(top.id == DeckID(100))
        #expect(top.name == "Korean")
        #expect(top.fullName == "Korean")
        #expect(top.children.count == 1)

        let child = top.children[0]
        #expect(child.id == DeckID(200))
        #expect(child.fullName == "Korean::Vocab")
        #expect(child.counts == DeckCounts(newCount: 4, learnCount: 1, reviewCount: 7))
    }

    // MARK: - deckCounts

    @Test func deckCounts_dispatches_to_decks_service_getDeckTree_method() {
        let request: Request<DeckCounts?> = .deckCounts(for: DeckID(42))
        #expect(request.serviceId == ServiceID.decks)
        #expect(request.methodId == DecksMethod.getDeckTree)
    }

    @Test func deckCounts_returns_counts_for_matching_node() throws {
        var vocab = Anki_Decks_DeckTreeNode()
        vocab.deckID = 200
        vocab.name = "Vocab"
        vocab.newCount = 4
        vocab.learnCount = 1
        vocab.reviewCount = 7
        var korean = Anki_Decks_DeckTreeNode()
        korean.deckID = 100
        korean.name = "Korean"
        korean.children = [vocab]
        var root = Anki_Decks_DeckTreeNode()
        root.children = [korean]

        let bytes = try root.serializedData()
        let decoded = try Request<DeckCounts?>.deckCounts(for: DeckID(200)).decode(bytes)

        #expect(decoded == DeckCounts(newCount: 4, learnCount: 1, reviewCount: 7))
    }

    @Test func deckCounts_returns_nil_when_deck_missing() throws {
        var korean = Anki_Decks_DeckTreeNode()
        korean.deckID = 100
        korean.name = "Korean"
        var root = Anki_Decks_DeckTreeNode()
        root.children = [korean]

        let bytes = try root.serializedData()
        let decoded = try Request<DeckCounts?>.deckCounts(for: DeckID(999)).decode(bytes)

        #expect(decoded == nil)
    }

    // MARK: - filtered decks

    @Test func filteredDeckTemplate_dispatches_and_defaults_to_a_new_deck() throws {
        let envelope: Request<FilteredDeckTemplate> = .filteredDeckTemplate()
        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.getOrCreateFilteredDeck)
        let proto = try Anki_Decks_DeckId(serializedBytes: envelope.body)
        #expect(proto.did == 0, "DeckID(0) is what asks the backend for a blank template")
    }

    @Test func filteredDeckTemplate_encodes_an_existing_deck_id() throws {
        let envelope: Request<FilteredDeckTemplate> = .filteredDeckTemplate(for: DeckID(77))
        let proto = try Anki_Decks_DeckId(serializedBytes: envelope.body)
        #expect(proto.did == 77)
    }

    @Test func addOrUpdateFilteredDeck_overlays_the_spec_onto_the_template() throws {
        var backendDefaults = Anki_Decks_FilteredDeckForUpdate()
        backendDefaults.name = "Filtered Deck 1"
        backendDefaults.config.reschedule = true
        backendDefaults.config.previewAgainSecs = 60
        backendDefaults.config.searchTerms = [Anki_Decks_Deck.Filtered.SearchTerm()]
        let template = FilteredDeckTemplate(bytes: try backendDefaults.serializedData())

        let spec = FilteredDeckSpec(
            name: "Leeches",
            searchTerms: [
                FilteredDeckSearchTerm(search: "is:due tag:leech", limit: 25, order: .lapses)
            ],
            reschedule: false
        )
        let envelope: Request<DeckCreation> = .addOrUpdateFilteredDeck(template: template, spec: spec)

        #expect(envelope.serviceId == ServiceID.decks)
        #expect(envelope.methodId == DecksMethod.addOrUpdateFilteredDeck)

        let sent = try Anki_Decks_FilteredDeckForUpdate(serializedBytes: envelope.body)
        #expect(sent.id == 0)
        #expect(sent.name == "Leeches")
        #expect(sent.allowEmpty == false)
        #expect(sent.config.reschedule == false)
        #expect(sent.config.searchTerms.count == 1)
        #expect(sent.config.searchTerms[0].search == "is:due tag:leech")
        #expect(sent.config.searchTerms[0].limit == 25)
        #expect(sent.config.searchTerms[0].order == .lapses)
        #expect(
            sent.config.previewAgainSecs == 60,
            "fields the Swift mirror doesn't model must survive the round trip"
        )
    }

    @Test func addOrUpdateFilteredDeck_carries_an_existing_id_for_an_update() throws {
        let template = FilteredDeckTemplate(bytes: try Anki_Decks_FilteredDeckForUpdate().serializedData())
        var spec = FilteredDeckSpec(
            name: "Leeches",
            searchTerms: [FilteredDeckSearchTerm(search: "is:due tag:leech")],
            allowEmpty: true
        )
        spec.id = DeckID(1234)

        let envelope: Request<DeckCreation> = .addOrUpdateFilteredDeck(template: template, spec: spec)
        let sent = try Anki_Decks_FilteredDeckForUpdate(serializedBytes: envelope.body)
        #expect(sent.id == 1234)
        #expect(sent.allowEmpty)
    }

    @Test func addOrUpdateFilteredDeck_decodes_OpChangesWithId_into_DeckCreation() throws {
        var resp = Anki_Collection_OpChangesWithId()
        resp.id = 4242
        resp.changes.deck = true
        resp.changes.studyQueues = true
        let bytes = try resp.serializedData()

        let template = FilteredDeckTemplate(bytes: try Anki_Decks_FilteredDeckForUpdate().serializedData())
        let envelope: Request<DeckCreation> = .addOrUpdateFilteredDeck(
            template: template,
            spec: FilteredDeckSpec(name: "Leeches", searchTerms: [FilteredDeckSearchTerm(search: "is:due")])
        )
        let creation = try envelope.decode(bytes)
        #expect(creation.id == DeckID(4242))
        #expect(creation.changes == CollectionChanges(deck: true, studyQueues: true))
    }

    @Test func filteredDeckOrder_rawValues_match_the_proto_enum() {
        for order in FilteredDeckOrder.allCases {
            let wire = Anki_Decks_Deck.Filtered.SearchTerm.Order(rawValue: Int(order.rawValue))
            #expect(wire != nil, "FilteredDeckOrder.\(order) has no matching proto case")
            #expect(wire?.rawValue == Int(order.rawValue))
        }
        #expect(
            FilteredDeckOrder.allCases.count == Anki_Decks_Deck.Filtered.SearchTerm.Order.allCases.count,
            "the proto gained an order the AnkiKit mirror hasn't picked up"
        )
    }
}
