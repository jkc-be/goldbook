"""The class bar before a character's name stays visible in both themes."""
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


def luminance(colour):
    values = [c / 255 for c in channels(colour)]
    values = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]


def contrast(a, b):
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


class ClassColourTests(unittest.TestCase):
    def test_class_bars_keep_3_to_1_on_the_page_and_panels(self):
        # A coloured shape needs 3:1 against what it sits on; the name beside it
        # is ink, which the palette tests hold to 7:1.
        for theme, selector in (("light", ":root"), ("dark", ':root[data-theme="dark"]')):
            classes = {name: value for name, value in block(selector).items() if name.startswith("class-")}
            colours = palette(":root" if theme == "light" else selector)
            self.assertEqual(len(classes), 13, theme)
            for name, colour in classes.items():
                for place in ("page", "panel"):
                    self.assertGreaterEqual(round(contrast(colour, colours[place]), 2), 3, f"{theme} {name} on the {place}")


if __name__ == "__main__":
    unittest.main()
