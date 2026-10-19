"""Class-coloured character names keep 4.5:1 wherever a row draws them."""
from pathlib import Path
import re
import unittest

STYLE = (Path(__file__).resolve().parents[2] / "web/style.css").read_text()


def block(selector):
    """The custom properties of the first rule for `selector`."""
    start = STYLE.index(selector + " {")
    return dict(re.findall(r"--([a-z0-9-]+): (#[0-9a-f]{6});", STYLE[start:STYLE.index("}", start)]))


def palette(selector):
    """The generated palette's colours for `selector`."""
    generated = STYLE[STYLE.index("/* The addon's palettes"):]
    start = generated.index(selector + " {")
    return dict(re.findall(r"--([a-z0-9-]+): (#[0-9a-f]{6});", generated[start:generated.index("}", start)]))


def channels(colour):
    return [int(colour[index:index + 2], 16) for index in (1, 3, 5)]


def over(below, above, alpha):
    return "#" + "".join(f"{round(b + (a - b) * alpha):02x}" for b, a in zip(channels(below), channels(above)))


def luminance(colour):
    values = [c / 255 for c in channels(colour)]
    values = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


class ClassColourTests(unittest.TestCase):
    def test_light_class_names_keep_their_contrast_on_pages_panels_and_rows(self):
        classes = {name: value for name, value in block(":root").items() if name.startswith("class-")}
        colours = palette(":root")
        # --tint and --tint-strong: the gold at 10% and 16%, over a hovered and a selected row.
        backgrounds = {
            "page": colours["page"],
            "panel": colours["panel"],
            "hovered row": over(colours["panel"], colours["gold"], 0.10),
            "selected row": over(colours["panel"], colours["gold"], 0.16),
        }
        self.assertEqual(len(classes), 13)
        for name, colour in classes.items():
            for place, background in backgrounds.items():
                self.assertGreaterEqual(round(contrast(colour, background), 2), 4.5, f"{name} on the {place}")


if __name__ == "__main__":
    unittest.main()
