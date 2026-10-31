#!/bin/sh
# Builds Duper.jar. Needs JDK 21 and paper-api jar (path in $API).
set -e
cd "$(dirname "$0")"
API=${API:-$(ls ../.libs/*.jar | tr "\n" :)}
rm -rf out && mkdir out
javac --release 21 -cp "$API" -d out src/dev/harness/duper/Duper.java
cp resources/*.yml out/
jar cf Duper.jar -C out .
echo "Built Duper.jar"
