//
//  CardsRequestsTests.swift
//  AnkiProtoBridgeTests
//
//  Created by Vladimir Gusev on 13.05.2026.
//

import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
private import SwiftProtobuf

@Suite struct CardsRequestsTests {
    @Test func searchCardIds_dispatches_to_search_cards_and_decodes_ids() throws {
        let envelope: Request<[CardID]> = .searchCardIds(query: "is:due flag:0")
        #expect(envelope.serviceId == ServiceID.search)
        #expect(envelope.methodId == SearchMethod.searchCards)
        let proto = try Anki_Search_SearchRequest(serializedBytes: envelope.body)
        #expect(proto.search == "is:due flag:0")

        var response = Anki_Search_SearchResponse()
        response.ids = [4, 9]
        #expect(try envelope.decode(response.serializedData()) == [CardID(4), CardID(9)])
    }

    @Test func searchCardIds_rewrites_an_empty_query_to_every_deck() throws {
        let envelope: Request<[CardID]> = .searchCardIds(query: "")
        let proto = try Anki_Search_SearchRequest(serializedBytes: envelope.body)
        #expect(proto.search == "deck:*")
    }

    @Test func getCard_dispatches_and_encodes_id() throws {
        let envelope: Request<CardRecord> = .getCard(id: CardID(42))
        #expect(envelope.serviceId == ServiceID.cards)
        #expect(envelope.methodId == CardsMethod.getCard)
        let proto = try Anki_Cards_CardId(serializedBytes: envelope.body)
        #expect(proto.cid == 42)
    }

    @Test func getCard_decodes_into_CardRecord_with_flag_bits() throws {
        var card = Anki_Cards_Card()
        card.id = 7
        card.noteID = 3
        card.deckID = 1
        card.flags = 0b1010  // flag color = 2 (after & 0b111)
        let bytes = try card.serializedData()
        let envelope: Request<CardRecord> = .getCard(id: CardID(7))
        let record = try envelope.decode(bytes)
        #expect(record.id == CardID(7))
        #expect(record.flags & 0b111 == 2)
    }

    @Test func setFlag_dispatches_and_encodes_inputs() throws {
        let envelope: Request<Void> = .setFlag(cardIds: [CardID(1), CardID(2)], flag: 3)
        #expect(envelope.serviceId == ServiceID.cards)
        #expect(envelope.methodId == CardsMethod.setFlag)
        let proto = try Anki_Cards_SetFlagRequest(serializedBytes: envelope.body)
        #expect(proto.cardIds == [1, 2])
        #expect(proto.flag == 3)
    }

    @Test func removeCards_dispatches_and_encodes_id_list() throws {
        let envelope: Request<Void> = .removeCards(cardIds: [CardID(10), CardID(20)])
        #expect(envelope.serviceId == ServiceID.cards)
        #expect(envelope.methodId == CardsMethod.removeCards)
        let proto = try Anki_Cards_RemoveCardsRequest(serializedBytes: envelope.body)
        #expect(proto.cardIds == [10, 20])
    }
}
