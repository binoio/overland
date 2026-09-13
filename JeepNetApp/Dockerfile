# Runs the platform-independent JeepNetCore test suite on Linux.
# The SwiftUI app target is excluded automatically by Package.swift when the
# host is not macOS.
#
#   docker build -t jeepnet-core-tests -f JeepNetApp/Dockerfile JeepNetApp
#   docker run --rm jeepnet-core-tests
FROM swift:6.0-noble

WORKDIR /workspace
COPY Package.swift ./
COPY Sources/JeepNetCore ./Sources/JeepNetCore
COPY Tests/JeepNetCoreTests ./Tests/JeepNetCoreTests

RUN swift build --build-tests

CMD ["swift", "test", "--skip-build"]
