FROM registry.access.redhat.com/ubi9/python-311:latest
WORKDIR /opt/app-root/src
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY schema.sql vm_sync.py ./
USER 1001
CMD ["python", "vm_sync.py"]
