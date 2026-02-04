FROM semaphoreui/semaphore:latest

USER root

# Install Python packages required by Ansible collections
RUN apk add --no-cache python3 py3-pip && \
    pip3 install --break-system-packages docker jmespath

# Install Ansible Galaxy collections from requirements.yml
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml && \
    rm /tmp/requirements.yml

USER semaphore
