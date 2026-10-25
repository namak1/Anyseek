# Reference and acceptance checklist

Reference: Everything 1.4 classic desktop interface, official voidtools screenshots and documentation. Anyseek is an independent implementation, not an official port.

## Implemented interface changes in 0.3

- In-window File, Edit, View, Search, Bookmarks, Tools, Help menu strip.
- Narrow search field with history dropdown; optional filter bar.
- Search options inside the Search menu, with active flags in the status bar.
- Compact white result table and optional alternate rows.
- Optional split preview pane.
- Sidebar Options dialog controlling implemented general/results/view/font/history/index/folder/exclusion settings.
- Advanced Search dialog builds Boolean, phrase, path, extension, size and modified-date searches.

## Not equivalent yet

- Complete menu inventory, keyboard mapping and exact Windows control rendering.
- Every Options page and setting from Everything 1.4.
- Thumbnails/icon view modes, full shell context menus, batch rename and undo.
- Full query-language parity, content extraction for PDF/Office documents, run-history ranking and macros.
- Network servers, file-list import and SDK/CLI interfaces.
- NTFS-specific indexing cannot be reproduced on APFS with the same implementation.

A green build verifies implemented behaviour and rendering; it is not a certificate of Everything equivalence. Do not describe this version as indistinguishable or feature-complete.

Official references:
- https://www.voidtools.com/support/everything/Everything.Search.Window.png
- https://www.voidtools.com/support/everything/Everything.Advanced.Search.png
- https://www.voidtools.com/support/everything/Everything.Options.General.png
- https://www.voidtools.com/support/everything/Everything.Options.Results.png
- https://www.voidtools.com/support/everything/options/
