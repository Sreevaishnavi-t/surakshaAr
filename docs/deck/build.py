# -*- coding: utf-8 -*-
"""Fills the SIH 2026 idea template with SurakshaAR content.

Nothing about the template's design is touched: the background art, the header
image, the team-name oval, the footer bar and the slide numbering are all left
exactly as they came. Only the title text and the body copy are replaced, and a
second column is added beside the existing body box so the content has somewhere
to go.

Paragraphs are built by deep-copying a paragraph the template already contains
and swapping the text inside it. That is deliberate — assigning to
`text_frame.text` collapses a paragraph to one unstyled run, which would silently
drop the template's Arial face, its bullet character and its indent.
"""
import copy

from pptx import Presentation
from pptx.util import Inches, Pt

import content

TEMPLATE = "template.pptx"
OUTPUT = "SurakshaAR-SIH2026-Idea.pptx"

# Layout constants, in inches. Chosen to sit inside the template's own
# furniture: below the title and team oval, above the footer bar at 6.95.
BODY_TOP = 1.55
BODY_HEIGHT = 5.25
LEFT_X, COL_W = 0.62, 5.86
RIGHT_X = 6.85

HEAD_PT = 19
BODY_PT = 14

# The team-name badge sits at x 0.36-1.73 on every content slide. The title
# placeholder starts at 0.20 and centres its text, so a title longer than the
# template's two-word placeholder runs straight under the badge. Giving the
# title a safe area that starts clear of it fixes that without moving any of
# the template's own furniture.
TITLE_X, TITLE_W = 1.95, 9.25
# The template anchors its title box at y -0.05, which suits its own short
# placeholder but clips a larger cap-height off the top of the slide.
TITLE_Y, TITLE_H = 0.10, 1.15


# CT_TextParagraphProperties is a *sequence*, not a bag: OOXML fixes the order
# its children may appear in. Appending a bullet after the tabLst and defRPr
# that some template paragraphs carry produces a file PowerPoint opens without
# complaint and then renders with no bullet at all — which is exactly how one
# slide lost its bullets while the others kept theirs.
_PPR_ORDER = [
    "lnSpc", "spcBef", "spcAft",
    "buClrTx", "buClr",
    "buSzTx", "buSzPct", "buSzPts",
    "buFontTx", "buFont",
    "buNone", "buAutoNum", "buChar",
    "tabLst", "defRPr", "extLst",
]


def _insert_ordered(pPr, element):
    """Places `element` at its schema-mandated position among pPr's children."""
    ns = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
    name = element.tag.replace(ns, "")
    rank = _PPR_ORDER.index(name)
    for existing in pPr:
        other = existing.tag.replace(ns, "")
        if other in _PPR_ORDER and _PPR_ORDER.index(other) > rank:
            existing.addprevious(element)
            return
    pPr.append(element)


def find(slide, name):
    for shape in slide.shapes:
        if shape.name == name:
            return shape
    raise KeyError(f"{name} not found on slide")


def paragraph_templates(text_frame):
    """Returns a deep copy of a styled paragraph, to clone for new lines.

    Picks the first paragraph that actually contains a run. Template text boxes
    routinely open with an empty spacer paragraph, which carries no run
    properties and would give every cloned line the theme default instead of the
    template's Arial.
    """
    ns = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
    for para in text_frame.paragraphs:
        if para._p.findall(f"{ns}r"):
            return copy.deepcopy(para._p)
    raise ValueError("no paragraph with a run to copy styling from")


def clear_paragraphs(text_frame):
    body = text_frame._txBody
    for para in body.findall(
        "{http://schemas.openxmlformats.org/drawingml/2006/main}p"
    ):
        body.remove(para)


def add_line(text_frame, proto, text, *, size, bold=False, bullet=True,
             space_before=None):
    """Appends one paragraph cloned from `proto`, carrying its styling."""
    para = copy.deepcopy(proto)
    ns = "{http://schemas.openxmlformats.org/drawingml/2006/main}"

    # Collapse to a single run, then set its text — keeps the run properties
    # (typeface, charset) the template defined.
    runs = para.findall(f"{ns}r")
    for extra in runs[1:]:
        para.remove(extra)
    if not runs:
        raise ValueError("prototype paragraph has no run")
    run = runs[0]
    run.find(f"{ns}t").text = text

    rPr = run.find(f"{ns}rPr")
    rPr.set("sz", str(int(size * 100)))
    rPr.set("b", "1" if bold else "0")
    # Slide 2's prototype paragraph carries an underline, which made every
    # bullet on that slide render underlined while the others did not. Set it
    # explicitly rather than relying on what each prototype happened to have.
    rPr.set("u", "none")

    pPr = para.find(f"{ns}pPr")
    if pPr is not None:
        if bullet:
            # Tighter hanging indent than the template's 28pt default, which was
            # sized for three lines of placeholder rather than real content.
            pPr.set("marL", "182880")
            pPr.set("indent", "-182880")
            # Slide 2 inherited a diamond bullet from its layout while the rest
            # used a round one. Pin the template's own round bullet everywhere so
            # the deck reads as one document.
            for tag in ("buChar", "buAutoNum", "buNone", "buFont"):
                for node in pPr.findall(f"{ns}{tag}"):
                    pPr.remove(node)
            _insert_ordered(pPr, para.makeelement(
                f"{ns}buFont",
                {"typeface": "Arial", "pitchFamily": "34", "charset": "0"}))
            _insert_ordered(pPr, para.makeelement(f"{ns}buChar",
                                                  {"char": "•"}))
        else:
            pPr.set("marL", "0")
            pPr.set("indent", "0")
            for tag in ("buChar", "buAutoNum", "buFont"):
                for node in pPr.findall(f"{ns}{tag}"):
                    pPr.remove(node)
            _insert_ordered(pPr, para.makeelement(f"{ns}buNone", {}))
        pPr.set("algn", "l")  # justified text opens rivers at this column width
        if space_before is not None:
            existing = pPr.find(f"{ns}spcBef")
            if existing is not None:
                pPr.remove(existing)
            spc = para.makeelement(f"{ns}spcBef", {})
            pts = para.makeelement(f"{ns}spcPts", {"val": str(int(space_before * 100))})
            spc.append(pts)
            _insert_ordered(pPr, spc)

    text_frame._txBody.append(para)
    return para


def fill_column(shape, proto, header, bullets):
    tf = shape.text_frame
    clear_paragraphs(tf)
    tf.word_wrap = True
    add_line(tf, proto, header, size=HEAD_PT, bold=True, bullet=False)
    for i, line in enumerate(bullets):
        add_line(tf, proto, line, size=BODY_PT, bullet=True,
                 space_before=7 if i else 9)


def build():
    prs = Presentation(TEMPLATE)

    # Slide 7 is the template's own instruction sheet, which it tells you to
    # delete before submitting, and SIH caps the deck at six slides.
    xml_slides = prs.slides._sldIdLst
    slide_ids = list(xml_slides)
    rid = slide_ids[6].get(
        "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
    )
    prs.part.drop_rel(rid)
    xml_slides.remove(slide_ids[6])

    # --- Title slide -------------------------------------------------------
    title_box = find(prs.slides[0], "TextBox 9")
    tf = title_box.text_frame
    proto = paragraph_templates(tf)
    clear_paragraphs(tf)
    for label, value in content.TITLE_FIELDS:
        para = add_line(tf, proto, label + value, size=15, bullet=False,
                        space_before=10)
        # Bold just the label, so the fields scan as a form.
        ns = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
        run = para.find(f"{ns}r")
        run.find(f"{ns}t").text = label
        run.find(f"{ns}rPr").set("b", "1")
        tail = copy.deepcopy(run)
        tail.find(f"{ns}t").text = value
        tail.find(f"{ns}rPr").set("b", "0")
        para.append(tail)

    # --- Content slides ----------------------------------------------------
    for number, spec in content.SLIDES.items():
        slide = prs.slides[number - 1]

        title = find(slide, "Title 1")
        title_tf = title.text_frame
        title_proto = paragraph_templates(title_tf)
        clear_paragraphs(title_tf)
        title.left, title.width = Inches(TITLE_X), Inches(TITLE_W)
        title.top, title.height = Inches(TITLE_Y), Inches(TITLE_H)
        add_line(title_tf, title_proto, spec["title"],
                 size=(24 if len(spec["title"]) > 36
                       else 28 if len(spec["title"]) > 26 else 34),
                 bold=True, bullet=False)

        # The template's own team-name badge. Marked with the same guillemets as
        # the title-slide blanks, so every value the team still has to supply is
        # one find-and-replace away rather than scattered across five slides.
        for shape in slide.shapes:
            if (shape.has_text_frame
                    and shape.text_frame.text.strip() == "Your Team Name"):
                for para in shape.text_frame.paragraphs:
                    for i, run in enumerate(para.runs):
                        run.text = "Technova" if i == 0 else ""
                        # The badge is 1.37in wide; the placeholder size wrapped
                        # the name across two lines inside the oval.
                        run.font.size = Pt(12)

        body = find(slide, "TextBox 8")
        proto = paragraph_templates(body.text_frame)

        # Reuse the template's own box as the left column.
        body.left, body.top = Inches(LEFT_X), Inches(BODY_TOP)
        body.width, body.height = Inches(COL_W), Inches(BODY_HEIGHT)
        # spAutoFit would shrink the box back around the old two lines.
        body.text_frame.auto_size = None
        fill_column(body, proto, spec["left_head"], spec["left"])

        # Second column: a copy of the same box, so it inherits every property.
        right_el = copy.deepcopy(body._element)
        body._element.addnext(right_el)
        right = [s for s in slide.shapes if s._element is right_el][0]
        right.name = "TextBox 8 Right"
        right.left = Inches(RIGHT_X)
        right.top = Inches(BODY_TOP)
        right.width = Inches(COL_W)
        right.height = Inches(BODY_HEIGHT)
        fill_column(right, proto, spec["right_head"], spec["right"])

    prs.save(OUTPUT)
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    build()
