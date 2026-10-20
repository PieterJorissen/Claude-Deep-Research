---
description: Run the full multi-stage research process on a topic
agent: researcher
---

I need comprehensive research on: $ARGUMENTS

Follow this process:

1. **Initial exploration** - Call `deepresearch_deep_research` with `sources: "both"` to
   gather web and academic material on the topic.

2. **Preliminary synthesis** - Organize the findings: main concepts, competing
   perspectives, and the gaps. Write them to `research/<slug>-notes.md` with sections for
   methodology, key findings, and open questions.

3. **Visual representation** - Where it helps, add a Mermaid timeline for chronology, a
   Mermaid graph for how ideas relate, a flowchart for a process, or a table for
   comparisons and figures. Keep them in the markdown.

4. **Follow-up research** - Name the 2-3 aspects that need more depth and run targeted
   follow-up searches with narrower queries.

5. **Comprehensive synthesis** - Write `research/<slug>-report.md` with an executive
   summary, methodology, key findings with visuals, analysis and interpretation, and
   conclusions and implications. Say how the follow-up searches closed the gaps from
   step 2.

6. **References** - APA 7th edition, covering every source used:
   - Web: Author, A. A. (Year, Month Day). Title of page. Site Name. URL
   - Academic: Author, A. A., & Author, B. B. (Year). Title of article. Journal Name,
     Volume(Issue), page range. DOI or URL

   Cite only what the tool returned. Where a claim rests on a page excerpt rather than the
   full text, say so.

Finish with the report path and the two or three things a reader should know before
trusting it.
