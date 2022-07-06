#!/usr/bin/env bash
set -e

GITHUB_WORKFLOW_NO_KEY_WARNING="WARNING: Using GITHUB_TOKEN instead of Deploy Key. Github Action Workflows will not be triggered."
PR_BODY_TEXT=${PR_BODY_TEXT:-This Automated PR updates the requirements.txt files to the latest versions. As this is automated it should be reviewed for errors before merging.}
PR_TITLE=${PR_TITLE:-Automated Requirements File Updates}
COMMIT_MESSAGE=${COMMIT_MESSAGE:-Updating versions for python lockfiles.}

# Configure git
echo Configuring git

## Needed to work around permissions issues.
git config --global --add safe.directory "${GITHUB_WORKSPACE}"
git config --global --add safe.directory /github/workspace

## User must be configured to commit.
git config --global user.name "${GITHUB_USERNAME:-$GITHUB_ACTOR}"
git config --global user.email "${GITHUB_USERNAME:-$GITHUB_ACTOR}@users.noreply.github.com"

# In case build keys use Github.
mkdir -p ~/.ssh/
ssh-keyscan github.com >> ~/.ssh/known_hosts



## Configure Remote
if [[ -z $DEPLOY_KEY ]]; then
  # If no deploy key is added fall back to the access token
  echo $GITHUB_WORKFLOW_NO_KEY_WARNING
  git remote set-url origin "https://${GITHUB_ACTOR}:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}"
  PR_BODY_TEXT="${PR_BODY_TEXT} \n\n $GITHUB_WORKFLOW_NO_KEY_WARNING"
else
  if [[ -z $SSH_AUTH_SOCK ]]
  then
    echo "Starting SSH Agent"
    echo "SSH_AUTH_SOCK=/tmp/ssh_auth.sock" >> $GITHUB_ENV
    ssh-agent -a /tmp/ssh_auth.sock > /dev/null
    export SSH_AUTH_SOCK=/tmp/ssh_auth.sock
  else
    echo "Agent is already running."
  fi

  echo "Configuring Git for SSH"
  git remote set-url origin git@github.com:${GITHUB_REPOSITORY}.git
fi



# Switch Branches
NEW_BRANCH_NAME=${BRANCH_PREFIX:-"pip-update"}-$(date +%s)
echo Creating and switching to branch $NEW_BRANCH_NAME.
git fetch --depth=1
git checkout -B $NEW_BRANCH_NAME


# Run pip-tools

## Generate CLI arguments
PIP_COMPILE_ARGS="--upgrade"
if [[ ! -z $PIP_ARGS ]]; then
  PIP_COMPILE_ARGS="$PIP_COMPILE_ARGS --pip-args $PIP_ARGS"
fi

if [[ ! -z $INDEX_URL ]]; then
  PIP_COMPILE_ARGS="$PIP_COMPILE_ARGS --index-url $INDEX_URL"
fi

if [[ ! -z $ALLOW_PRERELEASE && $ALLOW_PRERELEASE == "true" ]]; then
  PIP_COMPILE_ARGS="$PIP_COMPILE_ARGS --pre"
fi

## Base Requirements- available on all projects.
echo "Compiling core requirements.txt file."
pip-compile $PIP_COMPILE_ARGS --output-file requirements.txt

## Iterate over User Supplied Extras and create dedicated files for each.
if [[ ! -z $PIP_EXTRAS ]] ; then
  for extra in ${PIP_EXTRAS-:}
  do
    echo "Building lockfile for extra $extra"
    pip-compile $PIP_COMPILE_ARGS --extra $extra --output-file requirements-$extra.txt
  done
fi

# Add any changed file.
echo "Adding changes to git."
git add requirements*

GIT_STATUS=$(git status -s)
if [[ -z GIT_STATUS ]]; then
  echo "No updates to push- your lockfiles were already up to date."
  exit 0
fi
echo $GIT_STATUS

if [[ ! -z $DEPLOY_KEY ]]; then
  echo "Removing build keys from Agent to avoid conflicts with Deploy Key"
  ssh-add -D

  echo "Adding Deploy Key to to Agent"
  ssh-add - <<< "$DEPLOY_KEY"

  echo "Setting git remote to use SSH"
  git remote set-url origin git@github.com:${GITHUB_REPOSITORY}.git
fi

echo "Committing changes to git and pushing to Github."
git commit -m "$COMMIT_MESSAGE"
git push


set -x
echo "Creating Pull Request."
echo $GITHUB_TOKEN | gh auth login --with-token
echo -e $PR_BODY_TEXT | gh pr create --base ${BASE_BRANCH:-main} --title "$PR_TITLE" -F -
