# Orbit

Use Orbit for all user-facing app names, repository branding, IPA filenames, artifacts, workflows, documentation and new code names.

Keep the existing bundle identifiers, Keychain service/account names, disk-cache location and operational backend URLs/process names compatible with installed versions. Do not rename these persisted or server-side identifiers as part of branding changes. Never commit credentials.

Build the Orbit scheme in Orbit.xcodeproj, generated from project.yml. IPA output is Orbit.ipa; artifact name is Orbit-IPA. Run the existing full workflow when changing build/project/module names.
