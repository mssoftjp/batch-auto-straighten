# Interface writing

Reviewed against Apple's public guidance on September 27, 2026. English is this
project's primary UI language, with a Japanese translation. Keep Lightroom's own
names, such as Crop & Straighten, Develop, History and Quick Collection, and
their Japanese equivalents.

## Guidance and application

| Source | Application in this plug-in |
|---|---|
| [HIG: Writing](https://developer.apple.com/design/human-interface-guidelines/writing) | Use familiar words, consistent terms and short, useful explanations. |
| [HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | Keep batch options in the start dialog, where their effects are relevant. Preserve useful defaults. |
| [HIG: Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) | Name the action or destination. Use Lightroom's standard controls and title case for English action buttons. |
| [HIG: Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) and [Icons](https://developer.apple.com/design/human-interface-guidelines/icons) | Show the angle-link state with a simple chain symbol and visible text. Explain the next action in the tooltip. |
| [HIG: Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | State the situation and a useful next step. Keep the safe review choice as the default. |
| [Apple Style Guide, June 2026](https://support.apple.com/guide/applestyleguide/welcome/web) | Match onscreen terms in instructions; distinguish selecting photos from choosing menu commands. |
| [WWDC26: Craft clear names for features and labels in your app](https://developer.apple.com/videos/play/wwdc2026/290/) | Check whether names fit the context, set accurate expectations and work in both languages. |

These principles apply within the limits of Lightroom's SDK. Lightroom controls
the window chrome, fonts and native control appearance. The batch options dialog
stays part of the plug-in's task instead of becoming a separate application
settings window.

## Local conventions

- Use title case for English dialog titles, section headings, action buttons and
  command-like menu choices. Use sentence case for field labels, radio options,
  statuses and explanatory text. Keep product and Lightroom feature names as they are.
- Start action labels with a verb: Straighten Photos, Apply Angle, Show Photo,
  View Guide. No Change is the label for the option that keeps an existing value.
- Use Cancel before a batch starts, Stop Batch while it is running, and Done to
  dismiss results. Stopping keeps completed adjustments. Close dismisses an
  unresolved recovery notice without acknowledging or restoring anything.
- Keep consequences next to the choice. Reset and Straighten has a visible note
  explaining that it also resets the crop. Review keeps Skip as the default;
  applying an angle beyond the limit requires an explicit action.
- All Remaining covers the current correction and any later corrections over the
  limit in this batch. Explain that scope in both visible text and tooltips.
- Use "current edits" to name the recovery action that preserves the photo. Name
  both crop and angle when describing restoration. Do not imply that a failed
  verification means the photo is unchanged.
- In Japanese, use concise action labels and polite explanatory sentences.
  Translate the meaning and consequence rather than following the English word order.
- Tooltips add detail, but essential consequences must also be visible. Keep the
  README and the offline installation guide in sync with the labels people see.
- Linked angle limits keep both fields editable. The chain button changes how the
  fields relate; it does not lock editing. Show the state in text as well as with
  the symbol, and disclose in the tooltip the value that relinking will apply.

## Verification

Keep localization keys and persisted option values stable when polishing copy.
Update the English `LOC` fallbacks together with both translation dictionaries,
and preserve format arguments. Run the localization checks and the existing Lua
tests. Before claiming visual validation, inspect each affected dialog in
Lightroom using the exact edited source. Local preview fixtures must not adjust
catalog photos.
