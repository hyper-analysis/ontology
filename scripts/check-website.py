"""Validate the buildless site, local links, and the published compiler example."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

site = Path(__file__).resolve().parents[1] / "website"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate ID: {attrs['id']}"
            self.ids.add(attrs["id"])
        for key in ("href", "src"):
            if key in attrs:
                self.links.append(attrs[key])
        if "aria-controls" in attrs:
            self.links.append("#" + attrs["aria-controls"])


page = Page()
page.feed((site / "index.html").read_text())
for link in page.links:
    url = urlsplit(link)
    if url.scheme or url.netloc:
        assert url.scheme == "https", f"Unexpected external URL: {link}"
        continue
    if url.path:
        assert (site / url.path).is_file(), f"Missing asset: {link}"
    elif url.fragment:
        assert url.fragment in page.ids, f"Missing fragment: {link}"
assert (site / "school.sql").read_text() == (site.parent / "examples/school.sql").read_text()
print("Static site links, assets, IDs and SQL example passed.")
