#!/bin/bash

# Branch name for which z-stream changes needs to be applied (e.g., "rhoai-2.20")
BRANCH=""

# Directory containing Tekton pipelinerun YAML files
PIPELINERUNS_DIR=""

# RHOAI-Build-Config directory (optional, for updating patch files)
RBC_DIR=""

# New version value (optional, will be calculated if not provided)
NEW_VERSION=""

# Flag to enable RHOAI-Build-Config updates
UPDATE_RBC=false
# Track if NEW_VERSION was provided via -v flag (vs calculated)
VERSION_PROVIDED=false

# Help message for script usage
usage() {
  echo "Usage  : $0 -b <branch> -d <pipelineruns_dir> [OPTIONS]"
  echo ""
  echo "Required Options:"
  echo "  -b <branch>           Branch name for which z-stream changes needs to be applied (e.g., 'rhoai-2.20')"
  echo "  -d <pipelineruns_dir> Directory containing tekton pipelinerun YAML files"
  echo ""
  echo "Optional Options (for RHOAI-Build-Config updates):"
  echo "  -r <rbc_dir>          Directory path to RHOAI-Build-Config repository"
  echo "  -v <new_version>      New version value (e.g., '2.25.2'). If not provided, will be calculated"
  echo "  --update-rbc          Enable RHOAI-Build-Config patch file updates"
  echo "  --update-tekton-fbc   Enable Tekton FBC fragment file updates (main branch)"
  echo "  --commit-and-push     Commit and push changes (requires DRY_RUN env var)"
  echo ""
  echo "Examples:"
  echo "  $0 -b rhoai-2.20 -d pipelineruns"
  echo "  $0 -b rhoai-2.25 -d pipelineruns -r /path/to/RHOAI-Build-Config --update-rbc"
  echo "  $0 -b rhoai-2.25 -d pipelineruns -r /path/to/RHOAI-Build-Config -v 2.25.2 --update-rbc"
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -b)
      BRANCH="$2"
      shift 2
      ;;
    -d)
      PIPELINERUNS_DIR="$2"
      shift 2
      ;;
    -r)
      RBC_DIR="$2"
      shift 2
      ;;
    -v)
      NEW_VERSION="$2"
      VERSION_PROVIDED=true
      shift 2
      ;;
    --update-rbc)
      UPDATE_RBC=true
      shift
      ;;
    --update-tekton-fbc)
      UPDATE_TEKTON_FBC=true
      shift
      ;;
    --commit-and-push)
      COMMIT_AND_PUSH=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Invalid option: $1" >&2
      usage
      ;;
  esac
done

# used gsed for MacOS
if [[ "$(uname)" == "Darwin" ]]; then
  if ! command -v gsed &>/dev/null; then
      echo "❌ Error: gsed is not installed. Please install it using 'brew install gnu-sed'."
      exit 1
  fi
  sed_command="gsed"
else
  sed_command="sed"
fi

# Function to validate branch format
validate_branch() {
  local branch="$1"
  if [[ ! "$branch" =~ ^rhoai-[0-9]+\.[0-9]+$ ]]; then
    echo "Error: branch '$branch' is not in the valid 'rhoai-x.y' format."
    return 1
  fi
  return 0
}

# Function to commit and push changes
commit_and_push() {
  local dry_run="${1:-false}"
  local pipelineruns_dir="${2:-}"
  
  echo ""
  echo "============================================================================"
  echo ">> Committing and Pushing Changes"
  echo "============================================================================"
  
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git config --global color.ui always
  
  if [[ -n "$pipelineruns_dir" ]]; then
    set -x
    git add "$pipelineruns_dir"
    git diff --staged
    set +x
  else
    git add -A
  fi
  
  # Check if there are any changes to commit
  if git diff --staged --quiet; then
    echo "No changes to commit."
  else
    git commit -m "[skip-sync] Z-stream Changes"
    
    # Check if dry_run is false and push changes if true
    if [[ "$dry_run" == 'false' ]]; then
      git push origin "$BRANCH"
      echo "✅ Changes pushed to $BRANCH"
    else
      echo "'dry_run' is enabled. No changes will be pushed."
    fi
  fi
}

# Validate required arguments
if [[ -z "$BRANCH" ]]; then
  echo "Error: Branch is required."
  usage
fi

# Validate branch format
if ! validate_branch "$BRANCH"; then
  exit 1
fi

# PIPELINERUNS_DIR is only required if not doing RBC-only updates
if [[ -z "$PIPELINERUNS_DIR" && "$UPDATE_RBC" != "true" ]]; then
  echo "Error: Pipelineruns directory is required when not using --update-rbc."
  usage
fi

# Validate RBC update requirements
if [[ "$UPDATE_RBC" == "true" ]]; then
  if [[ -z "$RBC_DIR" ]]; then
    echo "Error: RBC directory (-r) is required when --update-rbc is specified."
    usage
  fi
  if [[ ! -d "$RBC_DIR" ]]; then
    echo "❌ Error: RBC directory '$RBC_DIR' does not exist. Exiting..."
    exit 1
  fi
  # Check if yq is available (required for RBC updates)
  if ! command -v yq &>/dev/null; then
    echo "❌ Error: yq is not installed. Required for RHOAI-Build-Config updates."
    echo "   Install it from: https://github.com/mikefarah/yq"
    exit 1
  fi
fi

# Process pipelineruns only if directory is provided
if [[ -n "$PIPELINERUNS_DIR" ]]; then
  # Ensure pipelineruns directory exists
  if [[ ! -d "$PIPELINERUNS_DIR" ]]; then
    echo "❌ Error: Directory '$PIPELINERUNS_DIR' does not exist. Exiting..."
    exit 1
  fi

  hyphenated_version=$(echo "$BRANCH" | sed -e 's/^rhoai-/v/' -e 's/\./-/')

  # Print the values
  echo "-----------------------------------"
  echo "Pipelineruns Dir   : $PIPELINERUNS_DIR"
  echo "Branch             : $BRANCH"
  echo "Hyphenated Version : $hyphenated_version"
  echo "-----------------------------------"

  # generate a single-line JSON string containing all folder names inside the pipelineruns directory
  folders=$(find ${PIPELINERUNS_DIR} -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | jq -R . | jq -s .)
  echo "Folders inside '$PIPELINERUNS_DIR' directory"
  echo "$folders" | jq .
  echo ""

  cd $PIPELINERUNS_DIR

  # Processing Tekton files in each folder one by one
  for folder in $(echo "$folders" | jq -r '.[]'); do
  echo "============================================================================"
  echo ">> Processing Tekton Files in Folder: $folder"
  echo "============================================================================"
  
  # Ensure .tekton directory exists
  tekton_dir="$folder/.tekton"
  if [[ ! -d "${tekton_dir}" ]]; then
    echo "❌ Error: Directory '${tekton_dir}' does not exist in branch '$BRANCH'. Exiting..."
    exit 1
  fi

  echo "Files inside .tekton:"
  find "${tekton_dir}" -type f -exec basename {} \; | sed 's/^/  - /'
  echo ""
  
  for file in ${tekton_dir}/*${hyphenated_version}-{push,scheduled}*.yaml; do
    
    if [ -f "$file" ]; then
      filename=$(basename $file)
      echo "Processing $(basename $filename)"

      # Updating version label
      konflux_application=$(yq '.metadata.labels."appstudio.openshift.io/application"' $file)

      # check to see if pipelineRefs are being used
      uses_pipeline_ref=$(yq '.spec | has("pipelineRef")' $file)
      
      if [[ "$uses_pipeline_ref" == "true" ]]; then
        echo "$filename appears to use pipelineRefs"
        label_version=$(yq '.spec.params[] | select(.name | test("^additional-labels")) | .value[] | select(test("^version=")) | sub("^version=";"")' $file) 
      else
        label_version=$(yq '.spec.pipelineSpec.tasks[] | select(.name | test("^(build-container|build-images)$")) | .params[] | select(.name == "LABELS") | .value[] | select(test("^version=")) | sub("^version="; "")' $file)
      fi
      echo "Detected label version: $label_version"

      # Extract major, minor, and micro version from RHOAI_VERSION
      MAJOR_VERSION=$(echo "$label_version" | cut -d'.' -f1 | tr -d 'v')
      MINOR_VERSION=$(echo "$label_version" | cut -d'.' -f2)
      MICRO_VERSION=$(echo "$label_version" | cut -d'.' -f3)

      # Determine Z-stream version
      Z_STREAM_VERSION="v${MAJOR_VERSION}.${MINOR_VERSION}.$((MICRO_VERSION + 1))"

      if [[ ( "$konflux_application" == *"external"* || "$konflux_application" == "automation" ) && -z "$label_version" ]]; then
        echo "  ⚠️  The external konflux component does not have 'version' LABEL set. Skipping!"
      elif [[ "$konflux_application" != *external* && -z "$label_version" ]]; then
        echo "  ❌ Error: The internal konflux component does not have 'version' LABEL set. Exiting!"
        exit 1
      else 
        if [[ "$uses_pipeline_ref" == "true" ]]; then
          ${sed_command} -i '/name: additional-tags/{n;:a;/version=/ {s/version=["]*[^""]*[""]*/version='"$Z_STREAM_VERSION"'/;b};n;ba}' $file

          # Modelmesh has an additional build argument that needs to be updated as well.
          # https://github.com/red-hat-data-services/modelmesh/blob/36ff14bc/.tekton/odh-modelmesh-v2-22-push.yaml#L41-L43
          if [[ $filename == odh-modelmesh-v*-push.yaml ]]; then
            echo "  🔔  updating VERSION in build-args!"
            ${sed_command} -i '/name: build-args/{n;:a;/VERSION=/ {s/VERSION=["]*[^""]*[""]*/VERSION='"$Z_STREAM_VERSION"'/;b};n;ba}' $file
          fi

        else
          ${sed_command} -i '/name: LABELS/{n;:a;/version=/ {s/version=["]*[^""]*[""]*/version='"$Z_STREAM_VERSION"'/;b};n;ba}' $file
        fi

        echo "  ✅ version="${label_version}" -> version="${Z_STREAM_VERSION}" "
      fi

    fi
    echo ""
  
  done

    echo ""
  done

  # Show changes made
  set -x
  git status
  git diff --color=always
  set +x
fi

# Function to extract version XY from branch (e.g., rhoai-2.25 -> 225)
extract_version_xy() {
  local branch="$1"
  echo "$branch" | sed 's/rhoai-//' | tr -d '.'
}

# Function to generate branch name for PRs
generate_branch_name() {
  local prefix="$1"
  local version="$2"
  local timestamp=$(date +%s)
  local version_sanitized=$(echo "$version" | tr '.' '-')
  echo "${prefix}-${version_sanitized}-${timestamp}"
}

# Function to update tekton FBC fragment files
update_tekton_fbc_files() {
  local rbc_path="$1"
  local branch="$2"
  
  echo ""
  echo "============================================================================"
  echo ">> Updating Tekton FBC Fragment Files"
  echo "============================================================================"
  echo "RBC Directory: $rbc_path"
  echo "Branch: $branch"
  echo ""
  
  cd "$rbc_path" || exit 1
  
  # Extract x.y from rhoai-x.y format (e.g., rhoai-2.16 -> 216)
  local version_xy=$(extract_version_xy "$branch")
  echo "Version pattern (xy): $version_xy"
  echo ""
  
  local files_updated=0
  local new_version=""
  
  # Find files matching pattern rhoai-fbc-fragment-rhoai-xy-ocp-*-push.yaml
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then
      echo "Processing file: $file"
      
      # Read current version value
      local current_version=$(yq eval '.spec.params[] | select(.name == "rhoai-version") | .value' "$file")
      
      if [[ -z "$current_version" || "$current_version" == "null" ]]; then
        echo "  ⚠️  Warning: Could not find rhoai-version parameter in $file"
        continue
      fi
      
      echo "  Current version: $current_version"
      
      # Parse version (major.minor.patch)
      IFS='.' read -ra VERSION_PARTS <<< "$current_version"
      local major=${VERSION_PARTS[0]}
      local minor=${VERSION_PARTS[1]}
      local patch=${VERSION_PARTS[2]}
      
      # Increment patch version
      local new_patch=$((patch + 1))
      new_version="${major}.${minor}.${new_patch}"
      
      echo "  New version: $new_version"
      
      # Update only the version value using sed (preserves YAML formatting)
      local escaped_current=$(printf '%s\n' "$current_version" | sed 's/[[\.*^$()+?{|]/\\&/g')
      ${sed_command} -i "/name: rhoai-version/{n;s/value: \"${escaped_current}\"/value: \"${new_version}\"/}" "$file"
      
      # Verify the update
      local updated_version=$(yq eval '.spec.params[] | select(.name == "rhoai-version") | .value' "$file")
      if [[ "$updated_version" == "$new_version" ]]; then
        echo "  ✅ Successfully updated: $current_version -> $new_version"
        files_updated=$((files_updated + 1))
      else
        echo "  ❌ Error: Failed to update version. Expected: $new_version, Got: $updated_version"
        cd - > /dev/null || exit 1
        return 1
      fi
      echo ""
    fi
  done < <(find .tekton -name "rhoai-fbc-fragment-rhoai-${version_xy}-ocp-*-push.yaml" -type f 2>/dev/null || true)
  
  
  if [[ $files_updated -eq 0 ]]; then
    echo "⚠️  No matching files found or updated"
    echo "   Pattern: rhoai-fbc-fragment-rhoai-${version_xy}-ocp-*-push.yaml"
  else
    echo "✅ Updated $files_updated file(s)"
  fi
  
  echo ""
  echo ">>> Summary of changes:"
  git diff --stat
  echo ""
  
  # Output for GitHub Actions
  if [[ -n "$GITHUB_OUTPUT" ]]; then
    echo "FILES_UPDATED=${files_updated}" >> "$GITHUB_OUTPUT"
    echo "new_version=${new_version}" >> "$GITHUB_OUTPUT"
  fi
  
  # Export for script use
  export TEKTON_NEW_VERSION="${new_version}"
  export TEKTON_FILES_UPDATED=${files_updated}
  
  echo ">>> New version calculated: $new_version"
  echo ""
  
  cd - > /dev/null || exit 1
  return 0
}

# Function to calculate new version from patch files
calculate_new_version() {
  local rbc_path="$1"
  
  echo ""
  echo "============================================================================"
  echo ">> Calculating New Version from Patch Files"
  echo "============================================================================"
  echo "RBC Directory: $rbc_path"
  echo ""
  
  cd "$rbc_path" || exit 1
  
  # Extract current version from bundle-patch.yaml or catalog-patch.yaml
  local current_version=""
  if [[ -f "bundle/bundle-patch.yaml" ]]; then
    current_version=$(yq eval '.patch.version' bundle/bundle-patch.yaml 2>/dev/null || echo "")
  fi
  
  if [[ -z "$current_version" || "$current_version" == "null" ]]; then
    if [[ -f "catalog/catalog-patch.yaml" ]]; then
      current_version=$(yq eval '.patch."olm.channels"[0].entries[0].name' catalog/catalog-patch.yaml 2>/dev/null | sed 's/rhods-operator\.//' || echo "")
    fi
  fi
  
  if [[ -z "$current_version" || "$current_version" == "null" ]]; then
    echo "❌ Error: Could not determine current version from patch files"
    cd - > /dev/null || exit 1
    return 1
  fi
  
  echo "Current version: ${current_version}"
  
  # Parse version (major.minor.patch)
  IFS='.' read -ra VERSION_PARTS <<< "$current_version"
  local major=${VERSION_PARTS[0]}
  local minor=${VERSION_PARTS[1]}
  local patch=${VERSION_PARTS[2]}
  
  # Increment patch version (x.y.z+1)
  local new_patch=$((patch + 1))
  local new_version="${major}.${minor}.${new_patch}"
  
  echo "New version: ${new_version}"
  echo ""
  
  # Output for GitHub Actions (if running in GitHub Actions)
  if [[ -n "$GITHUB_OUTPUT" ]]; then
    echo "old_version=${current_version}" >> "$GITHUB_OUTPUT"
    echo "new_version=${new_version}" >> "$GITHUB_OUTPUT"
    echo "NEW_VERSION=${new_version}" >> "$GITHUB_ENV"
  fi
  
  # Export for use in script
  export RBC_OLD_VERSION="${current_version}"
  export RBC_NEW_VERSION="${new_version}"
  
  echo ">>> Version calculation complete:"
  echo "    Old: ${current_version}"
  echo "    New: ${new_version}"
  echo ""
  
  cd - > /dev/null || exit 1
  return 0
}

# Function to update RHOAI-Build-Config patch files
update_rbc_patches() {
  local rbc_path="$1"
  local new_version="$2"
  
  echo ""
  echo "============================================================================"
  echo ">> Updating RHOAI-Build-Config Patch Files"
  echo "============================================================================"
  echo "RBC Directory: $rbc_path"
  echo "New Version: $new_version"
  echo ""
  
  cd "$rbc_path" || exit 1
  
  # Extract old version from bundle-patch.yaml or catalog-patch.yaml
  local old_version=""
  if [[ -f "bundle/bundle-patch.yaml" ]]; then
    old_version=$(yq eval '.patch.version' bundle/bundle-patch.yaml 2>/dev/null || echo "")
  fi
  
  if [[ -z "$old_version" || "$old_version" == "null" ]]; then
    if [[ -f "catalog/catalog-patch.yaml" ]]; then
      old_version=$(yq eval '.patch."olm.channels"[0].entries[0].name' catalog/catalog-patch.yaml 2>/dev/null | sed 's/rhods-operator\.//' || echo "")
    fi
  fi
  
  if [[ -z "$old_version" || "$old_version" == "null" ]]; then
    echo "⚠️  Warning: Could not determine old version, using new version"
    old_version="$new_version"
  fi
  
  echo "Old Version: $old_version"
  echo "New Version: $new_version"
  echo ""
  
  # 1. Update config files productVersion
  echo ">>> Updating config files productVersion..."
  if [[ -f "config/modelmesh-pig-build-config.yaml" ]]; then
    echo "  Updating config/modelmesh-pig-build-config.yaml"
    ${sed_command} -i "1s|#!productVersion=.*|#!productVersion=${new_version}|" config/modelmesh-pig-build-config.yaml
    echo "  ✅ Updated productVersion to ${new_version}"
  else
    echo "  ⚠️  config/modelmesh-pig-build-config.yaml not found"
  fi
  
  if [[ -f "config/trustyai-pig-build-config.yaml" ]]; then
    echo "  Updating config/trustyai-pig-build-config.yaml"
    ${sed_command} -i "1s|#!productVersion=.*|#!productVersion=${new_version}|" config/trustyai-pig-build-config.yaml
    echo "  ✅ Updated productVersion to ${new_version}"
  else
    echo "  ⚠️  config/trustyai-pig-build-config.yaml not found"
  fi
  
  # 2. Update bundle-patch.yaml version
  echo ""
  echo ">>> Updating bundle/bundle-patch.yaml..."
  if [[ -f "bundle/bundle-patch.yaml" ]]; then
    yq eval -i ".patch.version = \"${new_version}\"" bundle/bundle-patch.yaml
    echo "  ✅ Updated bundle patch version to ${new_version}"
  else
    echo "  ⚠️  bundle/bundle-patch.yaml not found"
  fi
  
  # 3. Update catalog-patch.yaml
  echo ""
  echo ">>> Updating catalog/catalog-patch.yaml..."
  if [[ -f "catalog/catalog-patch.yaml" ]]; then
    # Default skipRange pattern (can be overridden per channel if needed)
    local default_skip_range=">=2.24.0 <${new_version}"
    
    # Check if patch."olm.channels" exists (note: olm.channels is a single key with a dot, not nested)
    local has_channels=$(yq eval 'has("patch") and .patch | has("olm.channels")' catalog/catalog-patch.yaml 2>/dev/null || echo "false")
    
    if [[ "$has_channels" != "true" ]]; then
      echo "  ⚠️  Warning: No channels found in catalog-patch.yaml"
      echo "  Checking file structure..."
      yq eval '.' catalog/catalog-patch.yaml | head -20
      echo ""
      echo "  Skipping catalog-patch.yaml updates"
    else
      # Use quoted key name since olm.channels contains a dot
      local channel_count=$(yq eval '.patch."olm.channels" | length' catalog/catalog-patch.yaml 2>/dev/null || echo "0")
      
      if [[ -z "$channel_count" || "$channel_count" == "null" || "$channel_count" == "0" ]]; then
        echo "  ⚠️  Warning: No channels found in catalog-patch.yaml (channel_count: ${channel_count})"
        echo "  File structure:"
        yq eval '.patch' catalog/catalog-patch.yaml 2>/dev/null || echo "  Could not read .patch section"
      else
        echo "  Found ${channel_count} channel(s)"
        
        for i in $(seq 0 $((channel_count - 1))); do
          # Use quoted key name for olm.channels
          local channel_name=$(yq eval ".patch.\"olm.channels\"[$i].name" catalog/catalog-patch.yaml 2>/dev/null || echo "channel-$i")
          echo "  Processing channel $i (${channel_name})"
          local entry_count=$(yq eval ".patch.\"olm.channels\"[$i].entries | length" catalog/catalog-patch.yaml 2>/dev/null || echo "0")
          
          if [[ -z "$entry_count" || "$entry_count" == "null" || "$entry_count" == "0" ]]; then
            echo "    ⚠️  Warning: No entries found in channel $i"
            continue
          fi
          
          echo "    Found ${entry_count} entry/entries"
          
          for j in $(seq 0 $((entry_count - 1))); do
            # Get current name before any modifications
            local old_name=$(yq eval ".patch.\"olm.channels\"[$i].entries[$j].name" catalog/catalog-patch.yaml 2>/dev/null || echo "")
            
            if [[ -z "$old_name" || "$old_name" == "null" ]]; then
              echo "    ⚠️  Warning: Entry $j in channel $i has no name, skipping"
              continue
            fi
            
            # Calculate new name
            local new_name=$(echo "$old_name" | ${sed_command} "s/rhods-operator\.[0-9]\+\.[0-9]\+\.[0-9]\+/rhods-operator.${new_version}/")
            
            # Get and process skipRange
            local current_skip_range=$(yq eval ".patch.\"olm.channels\"[$i].entries[$j].skipRange" catalog/catalog-patch.yaml 2>/dev/null || echo "")
            local skip_range_to_use="${default_skip_range}"
            
            if [[ -n "$current_skip_range" && "$current_skip_range" != "null" ]]; then
              current_skip_range=$(echo "$current_skip_range" | ${sed_command} "s/^['\"]\(.*\)['\"]$/\1/")
              local lower_bound=$(echo "$current_skip_range" | ${sed_command} -n "s/\(>=[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p")
              [[ -n "$lower_bound" ]] && skip_range_to_use="${lower_bound} <${new_version}"
            fi
            
            echo "    Updating entry: ${old_name} -> ${new_name}"
            
            # Update all three fields sequentially (replaces must be set before name changes)
            yq eval -i ".patch.\"olm.channels\"[$i].entries[$j].replaces = \"${old_name}\"" catalog/catalog-patch.yaml
            yq eval -i ".patch.\"olm.channels\"[$i].entries[$j].name = \"${new_name}\"" catalog/catalog-patch.yaml
            yq eval -i ".patch.\"olm.channels\"[$i].entries[$j].skipRange = \"${skip_range_to_use}\"" catalog/catalog-patch.yaml
            
            # Ensure replaces is correct (re-set if needed)
            local verify_replaces=$(yq eval ".patch.\"olm.channels\"[$i].entries[$j].replaces" catalog/catalog-patch.yaml 2>/dev/null || echo "")
            if [[ "$verify_replaces" != "$old_name" ]]; then
              yq eval -i ".patch.\"olm.channels\"[$i].entries[$j].replaces = \"${old_name}\"" catalog/catalog-patch.yaml
            fi
          done
        done
        echo "  ✅ Updated catalog-patch.yaml"
      fi
    fi
  else
    echo "  ⚠️  catalog/catalog-patch.yaml not found"
  fi
  
  echo ""
  echo ">>> Summary of changes:"
  git diff --stat
  echo ""
  
  cd - > /dev/null || exit 1
}

# Update Tekton FBC fragment files if requested
if [[ "$UPDATE_TEKTON_FBC" == "true" ]]; then
  if [[ -z "$RBC_DIR" ]]; then
    echo "Error: RBC directory (-r) is required when --update-tekton-fbc is specified."
    usage
  fi
  if [[ ! -d "$RBC_DIR" ]]; then
    echo "❌ Error: RBC directory '$RBC_DIR' does not exist. Exiting..."
    exit 1
  fi
  if ! command -v yq &>/dev/null; then
    echo "❌ Error: yq is not installed. Required for Tekton FBC updates."
    echo "   Install it from: https://github.com/mikefarah/yq"
    exit 1
  fi
  
  update_tekton_fbc_files "$RBC_DIR" "$BRANCH"
fi

# Update RHOAI-Build-Config patches if requested
if [[ "$UPDATE_RBC" == "true" ]]; then
  # Calculate new version if not provided
  if [[ -z "$NEW_VERSION" ]]; then
    echo ">>> Calculating new version from patch files..."
    if ! calculate_new_version "$RBC_DIR"; then
      echo "❌ Error: Failed to calculate new version. Exiting..."
      exit 1
    fi
    # Use the calculated version
    NEW_VERSION="$RBC_NEW_VERSION"
    echo ">>> Using calculated version: ${NEW_VERSION}"
  else
    echo ">>> Using provided version: ${NEW_VERSION}"
    # Still calculate to get old version for reference
    calculate_new_version "$RBC_DIR" || true
  fi
  
  # Only update files if version was provided via -v flag
  # If version was calculated (not provided), we're in calculate-only mode
  if [[ "$VERSION_PROVIDED" == "true" ]]; then
    update_rbc_patches "$RBC_DIR" "$NEW_VERSION"
  else
    echo ">>> Version was calculated (not provided via -v): Skipping file updates"
    echo ">>> To update files, provide version using -v flag"
  fi
fi

# Commit and push changes if requested
if [[ "$COMMIT_AND_PUSH" == "true" ]]; then
  DRY_RUN_VALUE="${DRY_RUN:-false}"
  commit_and_push "$DRY_RUN_VALUE" "$PIPELINERUNS_DIR"
fi
