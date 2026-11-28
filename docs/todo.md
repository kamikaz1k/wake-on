# To do

Ideas and follow-ups not started yet. Things built but not yet checked on the phone live in
[verification](verification.md) under "Not verified yet".

## Features

- **Pictures and the camera.** Let the user attach a photo or open the camera during a chat so
  Pixie can see it (what is this, read this sign, what's wrong with this plant). Open questions:
  sending images to the voice model or to the backend lookup, the camera permission and its
  purpose string (today's string only covers WebRTC referencing the camera), the privacy policy
  and App Store privacy labels (photos would become collected data), and how a picture shows in
  the chat history.
- **MCP integration.** Let Pixie use MCP servers (the user's own tools and data) as tools in a
  call. Open questions: which servers and how they're added (URL plus auth in Settings), whether
  calls go from the phone or through the Pixie server, OAuth for remote servers, and showing MCP
  tool calls in the chat like the other tools.

## Follow-ups

- Home orb CPU and energy in a Release build (measured only in Debug on the simulator, 16-18%).
- Builds must use Xcode 27 / the iOS 27 SDK from April 2027 (App Store Connect warning).
- External TestFlight review: the Nov 22 build has waited since Nov 22; newer builds aren't submitted.
