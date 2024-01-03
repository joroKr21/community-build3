#!/usr/bin/env bash

set -e

if [ $# -ne 5 ]; then
  echo "Wrong number of script arguments, expected 3 $0 <repo_dir> <scala_version> <publish_version>, got $#: $@"
  exit 1
fi

projectName="$1"
repoDir="$2" # e.g. /tmp/shapeless
scalaVersion="$3" # e.g. 3.1.2-RC1
publishVersion="$4" # version of the project
projectConfig="$5" 

export OPENCB_PROJECT_DIR=$repoDir

scriptDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

MILL_0_11=0.11.6
MILL_0_10=0.10.12
MILL_0_9=0.9.12
RESOLVE="resolve _"

cd $repoDir
millVersion=
if [[ -f .mill-version ]];then
  millVersion=`cat .mill-version`
  echo "Found explicit mill version $millVersion"
else
  echo "No .mill-version file found, detecting compatible mill version"
  if [[ -f ./mill ]];then
    millVersion=`./mill -v $RESOLVE | grep "[Mm]ill.*version" | grep -E -o "(\d+\.?){3}"`
  else 
    for v in $MILL_0_11 $MILL_0_10 $MILL_0_9; do
      if ${scriptDir}/millw --mill-version $v $RESOLVE > /dev/null 2>/dev/null; then
        millVersion=$v
        break
      fi
    done 
  fi
  if [[ -z "$millVersion" ]];then
    echo "Failed to resolve correct mill version, abort"
    exit 1
  else
    # Force found version in build
    echo $millVersion > .mill-version
  fi
fi # detect version

millBinaryVersion=`echo $millVersion | cut -d . -f 1,2`
echo "Detected mill version=$millVersion, binary version: $millBinaryVersion"
millBinaryVersionMajor=`echo $millVersion | cut -d . -f 1`
millBinaryVersionMinor=`echo $millVersion | cut -d . -f 2`
# 0.9 is the minimal verified supported version
# 0.12 does not exit yet
if [[ "$millBinaryVersionMajor" -ne "0" || ( "$millBinaryVersionMinor" -lt "9" || "$millBinaryVersionMinor" -gt "11" ) ]]; then 
  echo "Unsupported mill version"
  exit 1
fi
ln $scriptDir/compat/$millBinaryVersion.sc MillVersionCompat.sc

# Base64 is used to mitigate spliting json by whitespaces
for elem in $(echo "${projectConfig}" | jq -r '.sourcePatches // [] | .[] | @base64'); do
  function field() {
    echo ${elem} | base64 --decode | jq -r ${1}
  }
  replaceWith=$(echo "$(field '.replaceWith')" | sed "s/<SCALA_VERSION>/${scalaVersion}/")
  path=$(field '.path')
  pattern=$(field '.pattern')
  echo "Try apply source patch:"
  echo "Path:        $path"
  echo "Pattern:     $pattern"
  echo "Replacement: $replaceWith"

  set -x
  # Cannot determinate did sed script was applied, so perform two ops each time
  sed -i "s/$pattern/$replaceWith/" "$repoDir/$path" || true
  sed -i -E "s/$pattern/$replaceWith/" "$repoDir/$path" || true
  set +x
done

prepareScript="${OPENCB_SCRIPT_DIR:?OPENCB_SCRIPT_DIR not defined}/prepare-scripts/${projectName}.sh"
if [[ -f "$prepareScript" ]]; then
  if [[ -x "$prepareScript" ]]; then 
    echo "Execute project prepare script: ${prepareScript}"
    cat $prepareScript
    bash "$prepareScript"
  else echo "Project prepare script is not executable: $prepareScript"
  fi
else 
  echo "No prepare script found for project $projectName"
fi

# Rename build.sc to build.scala - Scalafix does ignore .sc files
# Use scala 3 dialect to allow for top level defs
cp build.sc build.scala \
  && scalafix \
    --rules file:${scriptDir}/scalafix/rules/src/main/scala/fix/Scala3CommunityBuildMillAdapter.scala \
    --files build.scala \
    --stdout \
    --syntactic \
    --settings.Scala3CommunityBuildMillAdapter.targetScalaVersion "$scalaVersion" \
    --settings.Scala3CommunityBuildMillAdapter.targetPublishVersion "$publishVersion" \
    --settings.Scala3CommunityBuildMillAdapter.millBinaryVersion "$millBinaryVersion" \
    --scala-version 3.1.0 > build.sc \
  && rm build.scala 

ln -fs $scriptDir/../shared/CommunityBuildCore.scala CommunityBuildCore.sc
ln -fs $scriptDir/MillCommunityBuild.sc MillCommunityBuild.sc