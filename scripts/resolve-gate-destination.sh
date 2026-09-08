#!/usr/bin/env bash

# Resolve one exact, available Xcode gate destination for the caller.
#
# Source this file so the exported value survives:
#   source scripts/resolve-gate-destination.sh
#
# An operator-supplied GATE_DESTINATION is authoritative, but must resolve for
# the generated HealthLog project/scheme. Without one, prefer a booted iPhone
# simulator and otherwise select the first available iPhone simulator. UUIDs
# are discovered at runtime; none are persisted in project state.

_healthlog_gate_project="${PROJECT:-HealthLog.xcodeproj}"
_healthlog_gate_scheme="${SCHEME:-HealthLog}"

_healthlog_gate_error() {
    printf 'resolve-gate-destination: %s\n' "$1" >&2
    return 1
}

_healthlog_validate_gate_destination() {
    xcodebuild \
        -project "$_healthlog_gate_project" \
        -scheme "$_healthlog_gate_scheme" \
        -destination "$1" \
        -showBuildSettings >/dev/null 2>&1
}

_healthlog_project_state() {
    local project_file="$_healthlog_gate_project/project.pbxproj"

    if [[ -e "$_healthlog_gate_project" && ! -d "$_healthlog_gate_project" ]]; then
        printf 'invalid\n'
    elif [[ ! -e "$project_file" ]]; then
        printf 'absent\n'
    elif [[ ! -f "$project_file" || ! -s "$project_file" ]]; then
        printf 'invalid\n'
    elif ! grep -Fq '// !$*UTF8*$!' "$project_file" ||
        ! grep -Fq 'archiveVersion =' "$project_file" ||
        ! grep -Fq 'isa = PBXProject;' "$project_file"
    then
        printf 'invalid\n'
    else
        printf 'valid\n'
    fi
}

_healthlog_simulator_udid() {
    local requested_destination="${1:-}"

    xcrun simctl list devices available -j 2>/dev/null | ruby -rjson -e '
      begin
        payload = JSON.parse(STDIN.read)
        requested = ARGV.fetch(0, "")
        fields = requested.split(",").map do |component|
          key, value = component.split("=", 2).map(&:strip)
          [key, value] if key && value
        end.compact.to_h

        if !requested.empty? && fields["platform"] != "iOS Simulator"
          exit 3
        end

        devices = payload.fetch("devices", {}).flat_map do |runtime, entries|
          entries.map do |device|
            next unless device.fetch("isAvailable", true)
            next unless device.fetch("deviceTypeIdentifier", "").include?(".iPhone-")
            device.merge("runtime" => runtime)
          end.compact
        end

        selected = if requested.empty?
          devices.find { |device| device["state"] == "Booted" } || devices.first
        else
          matches = devices
          matches = matches.select { |device| device["udid"] == fields["id"] } if fields["id"]
          matches = matches.select { |device| device["name"] == fields["name"] } if fields["name"]
          requested_os = fields["OS"]
          if requested_os && requested_os != "latest"
            normalized_os = requested_os.tr(".", "-")
            matches = matches.select do |device|
              device.fetch("runtime", "").end_with?("iOS-#{normalized_os}")
            end
          end
          matches.find { |device| device["state"] == "Booted" } || matches.first
        end

        print(selected.fetch("udid", "")) if selected
      rescue JSON::ParserError
        exit 2
      end
    ' "$requested_destination"
}

_healthlog_gate_project_state="$(_healthlog_project_state)"
if [[ "$_healthlog_gate_project_state" == "invalid" ]]; then
    _healthlog_gate_error "project exists but project.pbxproj is empty or malformed: $_healthlog_gate_project"
    return 1
fi

if [[ -n "${GATE_DESTINATION:-}" ]]; then
    if [[ "$_healthlog_gate_project_state" == "valid" ]]; then
        if ! _healthlog_validate_gate_destination "$GATE_DESTINATION"; then
            _healthlog_gate_error "operator-supplied GATE_DESTINATION is unavailable: $GATE_DESTINATION"
            return 1
        fi
    else
        if ! command -v xcrun >/dev/null 2>&1 || ! command -v ruby >/dev/null 2>&1; then
            _healthlog_gate_error "cannot validate GATE_DESTINATION before project generation; xcrun and ruby are required"
            return 1
        fi
        _healthlog_gate_udid="$(_healthlog_simulator_udid "$GATE_DESTINATION")"
        _healthlog_gate_status=$?
        if [[ $_healthlog_gate_status -ne 0 || -z "$_healthlog_gate_udid" ]]; then
            _healthlog_gate_error "operator-supplied GATE_DESTINATION is unavailable: $GATE_DESTINATION"
            return 1
        fi
    fi
else
    if ! command -v xcrun >/dev/null 2>&1; then
        _healthlog_gate_error "xcrun is unavailable; install/select Xcode or supply a valid GATE_DESTINATION"
        return 1
    fi
    if ! command -v ruby >/dev/null 2>&1; then
        _healthlog_gate_error "ruby is unavailable; supply a valid GATE_DESTINATION"
        return 1
    fi

    _healthlog_gate_udid="$(_healthlog_simulator_udid)"
    _healthlog_gate_status=$?

    if [[ $_healthlog_gate_status -ne 0 ]]; then
        _healthlog_gate_error "could not parse the available simulator inventory"
        return 1
    fi
    if [[ -z "$_healthlog_gate_udid" ]]; then
        _healthlog_gate_error "no available iPhone simulator exists; install an iOS runtime or supply GATE_DESTINATION"
        return 1
    fi

    GATE_DESTINATION="platform=iOS Simulator,id=$_healthlog_gate_udid"
    if [[ "$_healthlog_gate_project_state" == "valid" ]] &&
        ! _healthlog_validate_gate_destination "$GATE_DESTINATION"
    then
        _healthlog_gate_error "selected iPhone simulator is not a valid HealthLog destination: $GATE_DESTINATION"
        return 1
    fi
fi

export GATE_DESTINATION

printf 'Resolved GATE_DESTINATION=%s\n' "$GATE_DESTINATION" >&2

unset _healthlog_gate_project _healthlog_gate_scheme _healthlog_gate_project_state
unset _healthlog_gate_udid _healthlog_gate_status
unset -f _healthlog_gate_error _healthlog_validate_gate_destination _healthlog_project_state
unset -f _healthlog_simulator_udid
