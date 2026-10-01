//
//  CardReviewAITests.swift
//  GraveyardFeatureTests
//

import Foundation
import Testing
import AnkiKit
@testable import GraveyardFeature

@Suite struct CardReviewAITests {

    // MARK: - Reading replies

    @Test func aPlainJSONReplyGivesTextAndProposal() {
        let parsed = CardReviewReply.parse("""
            {"reply": "The dose is wrong.", "proposed_fields": [{"name": "Back", "value": "5 mg/kg"}]}
            """)
        #expect(parsed.text == "The dose is wrong.")
        #expect(parsed.proposal == [ProposedField(name: "Back", value: "5 mg/kg")])
    }

    @Test func codeFencesAndStrayWordsAroundTheJSONAreForgiven() {
        let parsed = CardReviewReply.parse("""
            Here you go:
            ```json
            {"reply": "Looks right.", "proposed_fields": null}
            ```
            """)
        #expect(parsed.text == "Looks right.")
        #expect(parsed.proposal == nil)
    }

    @Test func anEmptyProposalIsNoProposal() {
        let parsed = CardReviewReply.parse(#"{"reply": "Fine as it is.", "proposed_fields": []}"#)
        #expect(parsed.proposal == nil)
    }

    @Test func aReplyThatIsNotJSONIsShownAsItIs() {
        let parsed = CardReviewReply.parse("  The card is correct, but {vague} in places.  ")
        #expect(parsed.text == "The card is correct, but {vague} in places.")
        #expect(parsed.proposal == nil)
    }

    // MARK: - Applying proposals

    private func note(_ fields: [String]) -> NoteRecord {
        NoteRecord(
            id: NoteID(10), guid: "g", mid: NotetypeID(7), mod: 0,
            flds: fields.joined(separator: "\u{1f}"), sfld: fields.first ?? "", csum: 0
        )
    }

    @Test func proposedFieldsLandByNameIgnoringCase() throws {
        let updated = try #require(CardFieldEdits.applying(
            [ProposedField(name: "back", value: "<b>5 mg/kg</b>")],
            to: note(["Dose of X?", "10 mg/kg", "Extra"]),
            fieldNames: ["Front", "Back", "Extra"]
        ))
        #expect(CardFieldEdits.splitFields(updated.flds) == ["Dose of X?", "<b>5 mg/kg</b>", "Extra"])
        #expect(updated.id == NoteID(10))
    }

    @Test func theSortFieldFollowsAChangedFirstField() throws {
        let updated = try #require(CardFieldEdits.applying(
            [ProposedField(name: "Front", value: "Dose of Y?")],
            to: note(["Dose of X?", "10 mg/kg"]),
            fieldNames: ["Front", "Back"]
        ))
        #expect(updated.sfld == "Dose of Y?")
    }

    @Test func aRawLineBreakFromTheModelIsStoredAsBR() throws {
        let updated = try #require(CardFieldEdits.applying(
            [ProposedField(name: "Back", value: "Ptosis\nMydriasis\r\nDown and out")],
            to: note(["Q", "A"]),
            fieldNames: ["Front", "Back"]
        ))
        #expect(CardFieldEdits.splitFields(updated.flds)[1] == "Ptosis<br>Mydriasis<br>Down and out")
    }

    @Test func unknownFieldNamesAreSkippedAndReported() {
        let proposal = [ProposedField(name: "Answer", value: "x")]
        #expect(CardFieldEdits.applying(proposal, to: note(["Q", "A"]), fieldNames: ["Front", "Back"]) == nil)
        #expect(CardFieldEdits.unknownNames(in: proposal, fieldNames: ["Front", "Back"]) == ["Answer"])
    }

    @Test func aProposalThatChangesNothingIsNil() {
        let proposal = [ProposedField(name: "Front", value: "Q")]
        #expect(CardFieldEdits.applying(proposal, to: note(["Q", "A"]), fieldNames: ["Front", "Back"]) == nil)
    }

    @Test func aMissingTrailingFieldIsAddedRatherThanDropped() throws {
        let updated = try #require(CardFieldEdits.applying(
            [ProposedField(name: "Extra", value: "Mnemonic")],
            to: note(["Q", "A"]),
            fieldNames: ["Front", "Back", "Extra"]
        ))
        #expect(CardFieldEdits.splitFields(updated.flds) == ["Q", "A", "Mnemonic"])
    }

    // MARK: - Prompt

    @Test func theInstructionsCarryTheCardFieldsInOrder() {
        let card = CardSnapshot(
            notetypeName: "Basic",
            deckName: "1_Neuro_Life",
            fields: [.init(name: "Front", value: "CN III palsy?"), .init(name: "Back", value: "Down and out")]
        )
        let instructions = CardReviewPrompt.instructions(for: card)
        #expect(instructions.contains("\"Basic\" note in the deck \"1_Neuro_Life\""))
        #expect(instructions.contains("proposed_fields"))
        let front = instructions.range(of: "CN III palsy?")
        let back = instructions.range(of: "Down and out")
        #expect(front != nil && back != nil)
        if let front, let back {
            #expect(front.lowerBound < back.lowerBound)
        }
    }

    // MARK: - OpenAI request and response

    @Test func theRequestSendsTheInstructionsThenTheConversation() throws {
        let conversation = [
            CardReviewMessage(role: .user, text: "Check it"),
            CardReviewMessage(role: .assistant, text: "Fine.", raw: #"{"reply": "Fine.", "proposed_fields": null}"#),
        ]
        let request = try OpenAIChat.makeRequest(
            instructions: "You help…",
            conversation: conversation,
            apiKey: "sk-test",
            model: "gpt-6-sol"
        )
        #expect(request.url == OpenAIChat.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try JSONDecoder().decode(OpenAIChat.RequestBody.self, from: try #require(request.httpBody))
        #expect(body.model == "gpt-6-sol")
        #expect(body.messages == [
            OpenAIChat.Message(role: "system", content: "You help…"),
            OpenAIChat.Message(role: "user", content: "Check it"),
            OpenAIChat.Message(role: "assistant", content: #"{"reply": "Fine.", "proposed_fields": null}"#),
        ], "an assistant turn goes back exactly as it came, proposal included")
    }

    @Test func aSuccessfulResponseGivesTheMessageText() throws {
        let body = Data(#"{"choices": [{"message": {"role": "assistant", "content": "  {\"reply\": \"ok\"}  "}}]}"#.utf8)
        #expect(try OpenAIChat.content(from: body, statusCode: 200) == #"{"reply": "ok"}"#)
    }

    @Test func anErrorResponseCarriesOpenAIsExplanation() {
        let body = Data(#"{"error": {"message": "Incorrect API key provided"}}"#.utf8)
        #expect(throws: CardReviewError.service("Incorrect API key provided")) {
            try OpenAIChat.content(from: body, statusCode: 401)
        }
    }

    @Test func aRefusalIsAnError() {
        let body = Data(#"{"choices": [{"message": {"content": null, "refusal": "I can't help with that."}}]}"#.utf8)
        #expect(throws: CardReviewError.service("I can't help with that.")) {
            try OpenAIChat.content(from: body, statusCode: 200)
        }
    }
}
