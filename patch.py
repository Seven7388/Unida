with open("unida-installer.sh", "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "https://api.github.com/repos/Seven7388/Unida/commits?per_page=3" in line:
        lines[i] = "        curl -s \"https://api.github.com/repos/Seven7388/Unida/commits?per_page=3\" | grep '\"message\":' | cut -d '\"' -f 4 | sed 's/\\\\n.*//' | sed 's/^/- /'\n        echo \"=================\"\n"

with open("unida-installer.sh", "w") as f:
    f.writelines(lines)
