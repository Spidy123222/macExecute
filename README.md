# macExecute

**macExecute** is an iOS app designed to run macOS CLI applications on iOS using Mach-O patching and custom libraries.

> ⚠️ This is a work in progress. Only very simple apps work at the moment.

---

## FAQ

**Will this be on the App Store?**  
- Never. It requires JIT, and even without JIT, it would still need to be installed via SideStore or AltStore like LiveContainer.

**Will this run [Insert App Here]?**  
- Probably not. iOS is missing many libraries, functions and frameworks that most CLI apps depend on.
    - even if the library / framework exists, some functions that the binary may try to use will not be in the iOS version of that library

---

## Devleloper Tested Apps:

- `TestApp` (included in the repo)  
- `zsh` (barely functional; only built-in commands work)

---

## Credits

- [LiveContainer](https://github.com/LiveContainer/LiveContainer) – Mach-O patching and guidance.
- [SideStore](https://sidestore.io), [idevice](https://github.com/jkcoxson/idevice) and [StikJIT](https://stikdebug.xyz) – Emotional support 
