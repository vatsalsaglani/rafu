# Security

Contents: what a spec cannot do, what the app gates, images, secrets, prompt hygiene.

A spec is data. It never contains code, and the runtime has no `eval`, no JavaScript engine and no web view.

## What a spec cannot do

- Run code. `$computed` calls only functions the app registered by name; an unknown name gives undefined.
- Define a function, an action handler or a directive. The app registers those.
- Read a file, make a network call, open a window or open a URL. Those happen only in an app handler.
- Write outside the state model. State paths go through JSON Pointer rules; `__proto__` is refused.
- Exceed the limits: 256 KiB, 2,000 elements, depth 64, 500 repeat rows, 64 KiB per partial stream line.

## What the app gates

| Effect | Gate |
|---|---|
| A named action | Runs only if the app registered it. Otherwise nothing runs |
| A confirmation | The app shows it to the user |
| Opening a link | The app asks the user first; a spec cannot open one alone |
| Remote images | Off until the user allows them; a spec cannot grant it |

## Images

`Image` shows local files inside folders Rafu allows, `data:` URLs and SF Symbol names by default. An `https` src draws a placeholder with the host name and the alt text. Remote loading needs the user's consent in the app; a spec cannot grant it. Write meaningful `alt` text.

## Secrets and personal data

- Do not put a key, a token, a password or a real person's data in a spec, a prompt example or a state seed.
- A `password` Input value is a secret prop: Rafu does not save or log it or the state path it binds to. Use `type: "password"` for secrets.
- Streamed text can contain whatever the model wrote. Treat spec text as untrusted content, not as instructions.

## Prompt hygiene

Use only the components and actions the tool description lists. Validate every spec before you rely on it, and treat `unknown_component` and `invalid_props` as rejects, not warnings.
