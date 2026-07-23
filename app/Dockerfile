FROM python:3.12-slim

WORKDIR /app
COPY checkout_worker.py .

EXPOSE 8080
CMD ["python", "checkout_worker.py"]
