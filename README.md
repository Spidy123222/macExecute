# macExecute

**macExecute** is an iOS app designed to run macOS CLI applications on iOS using Mach-O patching and custom libraries.

> ⚠️ This is a work in progress. Only very simple apps work at the moment.

---

## FAQ

**Will this be on the App Store?**  
- Never. It requires JIT, and even without JIT, it would still need to be installed via SideStore or AltStore like LiveContainer.

**Will this run [Insert App Here]?**  
- Probably not. iOS is missing many libraries, functions and frameworks that most CLI apps depend on.
    - Even if a library or framework exists on iOS, differences in implementation between the macOS and iOS versions can cause compatibility issues and lead to application failures

**Is this Emulation?**
- No, macExecute runs all the apps natively 

---

## How this works

1. Patches the Executable to think its a iOS app
2. Patches the executable to become a dynamic library (Read more about this on the [LC github](https://github.com/LiveContainer/LiveContainer#patching-guest-executable))
3. Patches the executable to change external library paths from the macOS path to the iOS versions path (if exists)
4. runs main() using dlopen and dlsym

---

## Devleloper Tested Apps:

- `TestApp` (included in the repo)  
- `zsh` (barely functional; only built-in commands work)

---

## Credits

- [LiveContainer](https://github.com/LiveContainer/LiveContainer) – Mach-O patching and guidance.
- [SideStore](https://sidestore.io), [idevice](https://github.com/jkcoxson/idevice) and [StikJIT](https://stikdebug.xyz) – Emotional support 
