# Deck source

`../SurakshaAR-SIH2026-Idea.pptx` and `.pdf` are generated, not hand-edited.
Editing the `.pptx` directly works until the next rebuild overwrites it.

```
python build.py            # content.py + template.pptx -> SurakshaAR-SIH2026-Idea.pptx
./render.ps1               # -> render/deck.pdf and render/slide-N.png, via PowerPoint
```

`content.py` holds every word on the slides and nothing about how they look.
`build.py` holds the layout and touches none of the template's own furniture —
background art, header image, team oval, footer bar, slide numbering. Paragraphs
are made by deep-copying one the template already contains and swapping the text,
because assigning `text_frame.text` collapses a paragraph to a single unstyled run
and silently drops the template's face, bullet and indent.

`render.ps1` drives the real PowerPoint over COM rather than LibreOffice, so the
PNGs show the fonts a judge will actually see.

Two fields are still unfilled, marked with guillemets: the Problem Statement ID
and the Team ID, both of which come from the SIH portal. The theme is set to
Smart Education, which was assumed rather than confirmed.

Claims here are checked against the repository — test counts, the analysis grid
shape, and which parts are built versus specified. If you change one, change the
other.
