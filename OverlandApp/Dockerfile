# Runs the platform-independent OverlandCore test suite on Linux.
# The SwiftUI app target is excluded automatically by Package.swift when the
# host is not macOS.
#
#   docker build -t overland-core-tests -f OverlandApp/Dockerfile OverlandApp
#   docker run --rm overland-core-tests
FROM swift:6.0-noble

WORKDIR /workspace
COPY Package.swift ./
COPY Sources/OverlandCore ./Sources/OverlandCore
COPY Tests/OverlandCoreTests ./Tests/OverlandCoreTests

RUN swift build --build-tests

CMD ["swift", "test", "--skip-build"]
