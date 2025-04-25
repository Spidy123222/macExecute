# This is currently a WIP and only very simple apps work

# macExecute
macExecute is an iOS app made for running macOS CLI apps on iOS using Mach-O patching and edited libraries

### FAQ:
Will this be on the AppStore?
    - Never, Requires JIT (and even if JIT support was removed it would still need SideStore or AltStore)
Will this run [Insert App Here]?
    - Probably not, iOS is missing a bunch of libraries and frameworks that most CLI apps need to function


### Some apps that work include:
- TestApp (in the repo)
- zsh (barely and very buggy, only built in commands work)

## Credits
- [LiveContainer](https://github.com/LiveContainer/LiveContainer): Mach-O patching and help with this project.
- [SideStore](https://sidestore.io), [idevice](https://github.com/jkcoxson/idevice) and [StikJIT](https://stikdebug.xyz): Emotional Support
