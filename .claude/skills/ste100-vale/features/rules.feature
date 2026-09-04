Feature: Rules

    Scenario: No semicolons
        When I test "NoSemicolons"
        Then the output should contain exactly:
            """
            test.md:5:26:STE100.NoSemicolons:Do not use semicolons (STE-8.11).
            """

    Scenario: Noun cluster limit
        When I test "NounClusterLimit"
        Then the output should contain exactly:
            """
            test.md:3:18:STE100.NounClusterLimit:Noun cluster of more than three words: 'landing gear shock absorber' (STE-2.1).
            """

    Scenario: Procedure sentence length (20-word max)
        When I test "ProcedureSentenceLength"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100Procedure.SentenceLength:Procedure sentences must not exceed 20 words (found 21) (STE Section 5: Procedural writing).
            """

    Scenario: Description sentence length (25-word max)
        When I test "DescriptionSentenceLength"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100Description.SentenceLength:Description sentences must not exceed 25 words (found 27) (STE Section 6: Descriptive writing).
            """

    Scenario: Approved words only
        When I test "ApprovedWords"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100.ApprovedWords:'demo-begin' is not an approved word (STE-1.1).
            """

    Scenario: Approved noun used as a verb
        When I test "WordPartOfSpeechNoun"
        Then the output should contain exactly:
            """
            test.md:1:6:STE100.WordPartOfSpeechNoun:'demo-check' is approved as a noun only, not as a verb (STE-1.2).
            """

    Scenario: Approved verb used as a noun
        When I test "WordPartOfSpeechVerb"
        Then the output should contain exactly:
            """
            test.md:1:13:STE100.WordPartOfSpeechVerb:'demo-start' is approved as a verb only, not as a noun (STE-1.2).
            """

    Scenario: American spelling
        When I test "AmericanSpelling"
        Then the output should contain exactly:
            """
            test.md:1:5:STE100.AmericanSpelling:Use 'color' instead of 'colour'.
            """

    Scenario: No progressive tense
        When I test "NoProgressiveTense"
        Then the output should contain exactly:
            """
            test.md:1:10:STE100.NoProgressiveTense:Do not use progressive tense ('is running'). Use the simple form instead (STE Section 3: Verbs).
            """

    Scenario: Paragraph sentence limit
        When I test "ParagraphSentenceLimit"
        Then the output should contain exactly:
            """
            test.md:1:4:STE100.ParagraphSentenceLimit:Paragraph exceeds 6 sentences (found 7) (STE-6.7).
            """

    Scenario: No perfect tense
        When I test "NoPerfectTense"
        Then the output should contain exactly:
            """
            test.md:1:14:STE100.NoPerfectTense:Perfect tense ('has adjusted') is not an approved verb form (STE-3.4).
            """

    Scenario: Consistent terminology
        When I test "ConsistentTerminology"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100.ConsistentTerminology:Inconsistent terminology: use only one of 'install' or 'fit' throughout (STE-1.11).
            """

    Scenario: No passive voice in procedures
        When I test "ProcedurePassiveVoice"
        Then the output should contain exactly:
            """
            test.md:1:11:STE100Procedure.PassiveVoice:Passive voice ('was installed') is not allowed in procedures. Use active voice (STE Section 5: Procedural writing).
            """

    Scenario: Passive voice flagged for review in descriptions
        When I test "DescriptionPassiveVoice"
        Then the output should contain exactly:
            """
            test.md:1:11:STE100Description.PassiveVoice:Passive voice ('was installed'). Allowed only when the agent is genuinely unknown, review this usage (STE Section 6: Descriptive writing).
            """

    Scenario: No contractions
        When I test "NoContractions"
        Then the output should contain exactly:
            """
            test.md:3:10:STE100.NoContractions:Do not use contractions: use 'is not' instead of 'isn't' (STE-4.2).
            """

    Scenario: No Latin abbreviations
        When I test "LatinAbbreviations"
        Then the output should contain exactly:
            """
            test.md:3:28:STE100.LatinAbbreviations:Do not use Latin abbreviations: use 'for example' instead of 'e.g.' (STE GR-6).
            """

    Scenario: No phrasal verbs
        When I test "PhrasalVerbs"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100.PhrasalVerbs:Phrasal verb 'Shut down'. Use a single approved verb instead (STE Section 9: Writing practices).
            """

    Scenario: No "-ing" clause after a comma
        When I test "IngClauseAfterComma"
        Then the output should contain exactly:
            """
            test.md:3:26:STE100.IngClauseAfterComma:An "-ing" form after a comma acts as a verb. Write a new sentence with a real subject (STE-3.5).
            """

    Scenario: Safety labels are uppercase
        When I test "SafetyLabelFormat"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100.SafetyLabelFormat:Safety label 'Warning:' must be uppercase: WARNING, CAUTION, or NOTE (STE Section 7: Safety instructions).
            """

    Scenario: Conditions come before commands
        When I test "ConditionBeforeCommand"
        Then the output should contain exactly:
            """
            test.md:3:22:STE100Procedure.ConditionBeforeCommand:Trailing condition 'value if'. Put the condition before the command, divided by a comma (STE-5.4).
            """

    Scenario: Unverified modal ruling
        When I test "ModalVerbs"
        Then the output should contain exactly:
            """
            test.md:3:10:STE100Unverified.ModalVerbs:Unverified ruling: 'should' may not be an approved modal. STE approves can, will, and must (STE-3.2).
            """

    Scenario: Unverified dictionary word ruling
        When I test "DictionaryWordRulings"
        Then the output should contain exactly:
            """
            test.md:3:1:STE100Unverified.DictionaryWordRulings:Unverified ruling: use 'make sure that' instead of 'Ensure' (STE-1.3).
            """

    Scenario: Unverified and/or ruling
        When I test "AndOr"
        Then the output should contain exactly:
            """
            test.md:3:14:STE100Unverified.AndOr:Unverified ruling: 'and/or' is ambiguous. Write 'X, or Y, or both', or pick one (STE Section 8: Punctuation).
            """
