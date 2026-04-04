FROM debian:bookworm
RUN apt-get update && apt-get install -y git curl bash jq
COPY . /opt/subtract
WORKDIR /opt/subtract
SHELL ["/bin/bash", "-c"]
RUN echo -e "n\nn" | bash install.sh
