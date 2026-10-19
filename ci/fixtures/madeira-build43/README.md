# Frozen build 43 migration inputs

These unmodified source inputs are from Madeira revision
`279fd0f83170425db002fe25d6bd62f6355f497d` by Will Faust. They retain their
GPL-3.0-or-later license and Madeira Converter Exception, included here.
`source.json` records each original source hash. No libraries, game data,
credentials or application assets are included.

Historical migration regression tests compare these originals with maintained
shipping source. They must not read a future engine pin's Swift UI or project.
The legacy `madeira_*presentation`, control and JIT overlay helpers are test
fixtures only. Native API, component, header and build-receipt tests continue to
read actual engine sources. Application preparation never reads this directory.
