# Mouse input

The Windows player requests UIKit pointer lock while active, with a mouse
connected and its menus closed. Actual granted lock controls raw GCMouse input.
Losing capture releases held buttons. A request alone does not prove delivery.

A local tablet-trait override lets the render view participate on iPhone.
iOS can still refuse capture. Unlocked hover/contact input is clamped to the
viewport and released on cancellation or teardown. The user must enable
AssistiveTouch if needed; fallback motion and buttons have limits.

Test capture, motion, buttons, fallback drag, menus, and app switching on the
physical device. Host tests and simulator focus do not prove mouse delivery.
See [device testing](manual-validation-runbook.md).
