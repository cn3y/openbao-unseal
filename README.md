# OpenBao Unseal Script

A secure, automated script for unsealing OpenBao pods in Kubernetes clusters with encrypted key management using `age` encryption.

## Features

- 🔐 **Secure Key Storage**: Uses `age` encryption for storing unseal keys
- 🛡️ **Permission Validation**: Automatically checks and fixes insecure file permissions
- 🎯 **Flexible Pod Selection**: Unseal all pods or target specific ones
- 🔍 **Status Overview**: List all pods with their sealed/unsealed status
- 🧪 **Dry-Run Mode**: Test operations without making changes
- ⏱️ **Configurable Timeout**: Adjust timeout for slow clusters
- 📊 **Detailed Reporting**: Color-coded output and summary statistics
- ✅ **Error Handling**: Comprehensive validation and error reporting

## Prerequisites

- Kubernetes cluster with OpenBao deployed
- `kubectl` configured with access to the cluster
- Required packages:
```bash
  sudo apt install age jq coreutils
```

## Installation

1. **Clone the repository**:
```bash
   git clone https://github.com/cn3y/openbao-unseal-script.git
   cd openbao-unseal-script
```

2. **Make the script executable**:
```bash
   chmod +x openbao-unseal.sh
```

3. **Optional: Install globally**:
```bash
   sudo cp openbao-unseal.sh /usr/local/bin/openbao-unseal
```

## Initial Setup

### 1. Generate Age Key Pair
```bash
# Create directory for age keys
mkdir -p ~/.age

# Generate key pair
age-keygen -o ~/.age/openbao-key.txt

# The command will display your public key
# age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 2. Encrypt OpenBao Init File

After initializing OpenBao, you'll have a JSON file with unseal keys and root token:
```bash
# Create directory for encrypted files
mkdir -p ~/.openbao

# Encrypt the init file (replace age1xxx... with your public key from step 1)
age -r age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
    -o ~/.openbao/openbao-init.json.age \
    openbao-init.json

# Securely delete the plaintext file
shred -u openbao-init.json
```

### 3. Verify Permissions

The script will automatically check and fix permissions, but you can manually set them:
```bash
chmod 700 ~/.age ~/.openbao
chmod 600 ~/.age/openbao-key.txt
chmod 600 ~/.openbao/openbao-init.json.age
```

## Configuration

Edit the following variables in the script if your setup differs:
```bash
AGE_KEY_FILE="${HOME}/.age/openbao-key.txt"
ENCRYPTED_FILE="${HOME}/.openbao/openbao-init.json.age"
NAMESPACE="openbao"
OPENBAO_POD_LABEL="app.kubernetes.io/name=openbao"
LOCAL_PORT=8200
```

## Usage

### Basic Commands

**Unseal all pods**:
```bash
openbao-unseal.sh
```

**Unseal specific pod(s)**:
```bash
openbao-unseal.sh openbao-0
openbao-unseal.sh openbao-0 openbao-1 openbao-2
```

**List all pods with status**:
```bash
openbao-unseal.sh --list
```

**Show help**:
```bash
openbao-unseal.sh --help
```

### Advanced Options

**Dry-run mode** (simulate without changes):
```bash
openbao-unseal.sh --dry-run
openbao-unseal.sh -d openbao-0
```

**Custom timeout** (default: 30s):
```bash
openbao-unseal.sh --timeout 60
openbao-unseal.sh -t 45 openbao-0
```

**Combined options**:
```bash
openbao-unseal.sh -d -t 60 openbao-0 openbao-1
```

## Example Output

### Successful Unseal
```
[INFO] Checking file permissions security...
[INFO] File permissions security check completed ✓

[INFO] Decrypting unseal keys...
[INFO] Using 3 unseal keys
[INFO] Searching for all OpenBao pods...
[INFO] Found pods: openbao-0 openbao-1 openbao-2

[INFO] Processing pod: openbao-0
[WARN] Pod openbao-0 is sealed - starting unseal process...
[DEBUG]   Key 1/3 sent - progress: 1/3
[DEBUG]   Key 2/3 sent - progress: 2/3
[DEBUG]   Key 3/3 sent - progress: 3/3
[INFO] Pod openbao-0 successfully unsealed ✓

[INFO] Processing pod: openbao-1
[INFO] Pod openbao-1 is already unsealed ✓

[INFO] === Summary ===
Total pods:     3
Successful:     3
```

### List Pods
```
[INFO] Available OpenBao pods:

POD NAME             STATUS      SEALED
--------             ------      ------
openbao-0            Running     unsealed
openbao-1            Running     sealed
openbao-2            Running     sealed
```

### Permission Warning
```
[WARN] Insecure permissions detected for openbao-key.txt
[WARN]   Current: 644 (should be 600)
[WARN]   File: /home/user/.age/openbao-key.txt
[INFO] Setting secure permissions (600) for openbao-key.txt...
[INFO] Successfully set permissions to 600 for openbao-key.txt ✓
```

## How It Works

1. **Security Check**: Validates file permissions for age key and encrypted file
2. **Decryption**: Decrypts unseal keys using age
3. **Pod Discovery**: Finds OpenBao pods using Kubernetes labels
4. **Port Forwarding**: Establishes temporary port-forward to each pod
5. **Status Check**: Queries seal status via OpenBao API
6. **Unsealing**: Sends threshold keys (default: 3 of 5) sequentially
7. **Verification**: Confirms successful unseal
8. **Summary**: Reports statistics

## Security Considerations

### Best Practices

- **Age Key Protection**: The `~/.age/openbao-key.txt` is your master secret
  - Keep secure backups on separate, encrypted media
  - Never commit to version control
  - Never share or transmit over insecure channels

- **File Permissions**: Script enforces 600 (owner read/write only)
  
- **Access Control**: Only run from trusted systems with kubectl access

- **Backup Strategy**:
```bash
  # Backup encrypted file to separate location
  cp ~/.openbao/openbao-init.json.age /path/to/secure/backup/
  
  # Backup age key separately (on encrypted USB stick, password manager, etc.)
  cp ~/.age/openbao-key.txt /path/to/separate/secure/backup/
```

### What NOT to Do

❌ Never store plaintext unseal keys  
❌ Never commit age private key to git  
❌ Never store both age key and encrypted file in same backup location  
❌ Never share age key over email/chat  
❌ Never run with `sudo` unless absolutely necessary  

## Troubleshooting

### Port-forward fails
```
[ERROR] Port-forward for pod openbao-0 could not be started
```
**Solution**: Check if another process is using port 8200, or increase timeout:
```bash
openbao-unseal.sh --timeout 60 openbao-0
```

### Permission denied on age key
```
[ERROR] Cannot secure age key file permissions
```
**Solution**: Manually fix ownership:
```bash
sudo chown $USER:$USER ~/.age/openbao-key.txt
chmod 600 ~/.age/openbao-key.txt
```

### Decryption failed
```
[ERROR] Decryption failed
```
**Solution**: Verify you're using the correct age key that matches the encrypted file

### No pods found
```
[ERROR] No OpenBao pods found
```
**Solution**: 
- Check namespace: `kubectl get pods -n openbao`
- Verify pod labels match `OPENBAO_POD_LABEL` in script

## Integration Examples

### Systemd Service

Create a systemd service for automatic unseal after node reboot:
```ini
# /etc/systemd/system/openbao-unseal.service
[Unit]
Description=OpenBao Unseal Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=cn3y
ExecStart=/usr/local/bin/openbao-unseal.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable and test:
```bash
sudo systemctl daemon-reload
sudo systemctl enable openbao-unseal.service
sudo systemctl start openbao-unseal.service
sudo systemctl status openbao-unseal.service
```

### Cronjob

Periodic check and unseal:
```bash
# Run every hour to check and unseal if needed
0 * * * * /usr/local/bin/openbao-unseal.sh >/dev/null 2>&1
```

### Kubernetes Job

Deploy as a Kubernetes CronJob:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: openbao-unseal
  namespace: openbao
spec:
  schedule: "*/5 * * * *"  # Every 5 minutes
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: openbao-unseal
          containers:
          - name: unseal
            image: your-registry/openbao-unseal:latest
            command: ["/usr/local/bin/openbao-unseal.sh"]
            volumeMounts:
            - name: age-key
              mountPath: /root/.age
              readOnly: true
            - name: encrypted-keys
              mountPath: /root/.openbao
              readOnly: true
          volumes:
          - name: age-key
            secret:
              secretName: openbao-age-key
          - name: encrypted-keys
            secret:
              secretName: openbao-encrypted-keys
          restartPolicy: OnFailure
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Follow existing code style and conventions
- Test thoroughly with dry-run mode
- Update README.md if adding new features
- Add error handling for new functionality

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [OpenBao](https://openbao.org/) - Open source fork of HashiCorp Vault
- [age](https://age-encryption.org/) - Simple, modern file encryption tool
- Inspired by the need for secure, automated OpenBao management in homelab environments

## Support

- **Issues**: Report bugs via [GitHub Issues](https://github.com/cn3y/openbao-unseal-script/issues)
- **Discussions**: Join [GitHub Discussions](https://github.com/cn3y/openbao-unseal-script/discussions)
- **Security**: Report security vulnerabilities via private message to maintainers

## Changelog

### v1.0.0 (2024-12-29)
- Initial release
- Basic unseal functionality
- Age encryption support
- Permission validation
- Dry-run mode
- Timeout configuration
- Pod selection options
- Status listing

---

**⚠️ Security Notice**: This script handles sensitive cryptographic material. Always follow security best practices and keep your age private key secure.