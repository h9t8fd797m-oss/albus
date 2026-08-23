# The tool catalogue

`ios/App/Albus/Models/StudyTool.swift` is **generated**. Edit `gen.py`, then:

```bash
cd scripts/tools && python3 emit.py && cp StudyTool.swift ../../ios/App/Albus/Models/
```

`gen.py` holds one tuple per tool:

    (name, host, category, sfSymbol, tint, reason)

`gen.py` refuses to emit on a duplicate name or an unknown category, and
`AlbusTests/ToolCatalogTests` fails the build on an SF Symbol that does not
exist — which is the failure that matters, because a mistyped symbol renders a
blank tile and nothing else complains. Three were caught that way.

## Adding real brand logos

`ToolIcon` prefers an image asset named `logo-<tool id>` and falls back to the
symbol. Dropping artwork into the asset catalogue under those names is enough —
no code changes. Favicons are deliberately never fetched at runtime: it would
tell every one of these companies when a student opens the tab, cost a request
per tile, and break the screen offline.
