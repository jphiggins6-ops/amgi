//
//  FieldTextTests.swift
//  BrowseFeatureTests
//

import Testing
@testable import BrowseFeature

@Suite struct FieldTextTests {

    // MARK: - Which way a field is edited

    @Test func aFieldWhoseOnlyMarkupIsLineBreaksIsPlain() {
        #expect(FieldText.isPlain("{{c1::Ptosis<br>Mydriasis}}"))
        #expect(FieldText.isPlain("Na &lt; 135 &amp; K"))
        #expect(FieldText.isPlain(""))
    }

    @Test func formattingPicturesAndCommentsAreEditedAsSource() {
        #expect(!FieldText.isPlain("<b>Ptosis</b>"))
        #expect(!FieldText.isPlain(#"Eye<img src="eye.jpg">"#))
        #expect(!FieldText.isPlain("<!--amgi-mnemonic:pending:ab12:idea-->"))
        #expect(!FieldText.isPlain("<!-- <br> -->x"), "a comment is markup even with a <br> inside")
        #expect(!FieldText.isPlain(#"a<br class="x">b"#))
    }

    // MARK: - Plain

    @Test func plainFieldsShowLineBreaksAndStoreThemAsBR() {
        let field = "{{c1::Ptosis<br>Mydriasis<br><br>Down and out}}"
        let shown = FieldText.plainDisplay(field)
        #expect(shown == "{{c1::Ptosis\nMydriasis\n\nDown and out}}")
        #expect(FieldText.plainStored(shown) == field)
    }

    @Test func aRawLineBreakIsStoredAsTheBRTheCardNeeds() {
        // Shown as a break, so it's stored as one.
        #expect(FieldText.plainStored(FieldText.plainDisplay("Ptosis\nMydriasis")) == "Ptosis<br>Mydriasis")
        #expect(FieldText.plainStored(FieldText.plainDisplay("a<br>\nb")) == "a<br>b", "a <br> and the raw break after it are one line break")
        #expect(FieldText.plainStored("a\r\nb") == "a<br>b")
    }

    @Test func plainTextIsEscapedButEntitiesAreLeftAlone() {
        #expect(FieldText.plainStored("x<y & z") == "x&lt;y &amp; z")
        #expect(FieldText.plainStored(FieldText.plainDisplay("Na &lt; 135 &amp; K &#x27;s")) == "Na &lt; 135 &amp; K &#x27;s")
    }

    // MARK: - Source

    @Test func sourceFieldsPutEachBROnItsOwnLineAndRoundTripExactly() {
        let field = #"<b>Ptosis</b><br>Mydriasis<br><br><img src="eye.jpg">"#
        let shown = FieldText.sourceDisplay(field)
        #expect(shown == "<b>Ptosis</b><br>\nMydriasis<br>\n<br>\n<img src=\"eye.jpg\">")
        #expect(FieldText.sourceStored(shown) == field)
    }

    @Test func returnInSourceStartsANewLine() {
        #expect(FieldText.sourceStored("<b>Ptosis</b>\nMydriasis") == "<b>Ptosis</b><br>Mydriasis")
        #expect(FieldText.sourceStored(FieldText.sourceDisplay("<b>a</b><br>\nb")) == "<b>a</b><br>b")
    }

    @Test func sourceEditingKeepsCommentsAndPictures() {
        let field = #"<i>x</i><!--amgi-mnemonic:pending:ab12:idea--><img src="a.png">"#
        #expect(FieldText.sourceStored(FieldText.sourceDisplay(field)) == field)
    }
}
