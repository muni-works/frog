# Customize on the web: screenshots

Headless Chrome against the mock gateway (`apps/web/test/mock/mock-gateway.mjs`), desktop 1280×820
and phone 375×812, dark and light.

- `real-*`: what a signed-in account sees today. No engine report reaches the web yet, so no figure
  is drawn; what a Frog Cloud session reads from a repo is said in words, the Mac's half is an
  invitation.
- `sample-*`: **dev-only sample data** (`?customize=sample` under `npm run dev`, from
  `apps/web/src/customize.sample.ts`, the canvas frames' examples). Never in a production build. They
  show the designs (weight card, activity marks, tool squares, sheets, rail, week grid, the skill
  page) as they'll draw once a cloud session answers `{"op":"customize"}` (docs/customize-api.md).
