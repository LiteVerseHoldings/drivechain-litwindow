format:
    cd litwindow && dart format .

setup:
    bash scripts/install-hooks.sh

gen-router:
    cd litwindow && dart run build_runner build --delete-conflicting-outputs

upgrade:
    cd litwindow && flutter pub upgrade --tighten --major-versions

gen-version:
    bash scripts/generate-version.sh litwindow

gen: gen-router gen-version

test:
    cd litwindow && flutter test
