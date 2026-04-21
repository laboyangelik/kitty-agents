#!/usr/bin/env python3
"""
Prepends a new release entry to appcast.xml.
All values come from environment variables set by the workflow.
"""
import os
from datetime import datetime, timezone

version  = os.environ["RELEASE_VERSION"]
build    = os.environ["RELEASE_BUILD"]
sig      = os.environ["SPARKLE_SIG"]
length   = os.environ["RELEASE_LENGTH"]
repo     = os.environ["GITHUB_REPOSITORY"]
zip_name = os.environ["RELEASE_ZIP"]
url      = f"https://github.com/{repo}/releases/download/v{version}/{zip_name}"
date     = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")

new_item = (
    f"        <item>\n"
    f"            <title>v{version}</title>\n"
    f"            <description><![CDATA[<p>kitty agents {version}</p>]]></description>\n"
    f"            <pubDate>{date}</pubDate>\n"
    f"            <sparkle:version>{build}</sparkle:version>\n"
    f"            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
    f"            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n"
    f"            <enclosure\n"
    f"                url=\"{url}\"\n"
    f"                type=\"application/octet-stream\"\n"
    f"                sparkle:edSignature=\"{sig}\"\n"
    f"                length=\"{length}\"\n"
    f"            />\n"
    f"        </item>"
)

with open("appcast.xml") as f:
    content = f.read()

# Insert newest release before the first existing <item>, or before </channel>
if "<item>" in content:
    content = content.replace("<item>", new_item + "\n        <item>", 1)
else:
    content = content.replace("</channel>", new_item + "\n    </channel>")

with open("appcast.xml", "w") as f:
    f.write(content)

print(f"appcast.xml updated for v{version}")
