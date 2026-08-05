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
