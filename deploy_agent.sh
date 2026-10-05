#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

PROJECT_DIR=""

handle_deploy_interrupt() {
    echo
    echo "=============================================="
    echo "DEPLOYMENT INTERRUPTED"
    echo "=============================================="

    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
        local parent_dir
        local project_name
        local archive_file

        parent_dir="$(dirname "$PROJECT_DIR")"
        project_name="$(basename "$PROJECT_DIR")"
        archive_file="${parent_dir}/${project_name}_archive.zip"

        echo "Creating archive of incomplete project..."

        if zip -r "$archive_file" "$PROJECT_DIR" >/dev/null 2>&1; then
            echo "Incomplete project archived successfully:"
            echo "$archive_file"

            echo "Removing incomplete project directory..."
            rm -rf "$PROJECT_DIR"

            echo "Incomplete project directory removed."
        else
            echo "ERROR: Failed to create ZIP archive."
            echo "The incomplete project directory was left in place:"
            echo "$PROJECT_DIR"
        fi
    else
        echo "No project directory existed to archive."
    fi

    trap - SIGINT SIGTSTP

    echo "Deployment session closed cleanly."
    exit 130
}

check_templates() {
    echo
    echo "Checking template files..."

    if [ ! -f "$TEMPLATES_DIR/attendance_checker.py" ]; then
        echo "ERROR: templates/attendance_checker.py is missing."
        return 1
    fi

    if [ ! -f "$TEMPLATES_DIR/assets.csv" ]; then
        echo "ERROR: templates/assets.csv is missing."
        return 1
    fi

    if [ ! -f "$TEMPLATES_DIR/config.json" ]; then
        echo "ERROR: templates/config.json is missing."
        return 1
    fi

    echo "✓ All template files found."
    return 0
}

run_application() {
    local project_dir="$1"

    if [ ! -d "$project_dir" ]; then
        echo "ERROR: Project directory does not exist."
        return 1
    fi

    if [ ! -f "$project_dir/attendance_checker.py" ]; then
        echo "ERROR: attendance_checker.py is missing."
        return 1
    fi

    echo
    echo "=============================================="
    echo "          RUNNING ATTENDANCE CHECKER"
    echo "=============================================="

    cd "$project_dir" || return 1

    python3 attendance_checker.py
    local exit_code=$?

    cd "$SCRIPT_DIR" || return 1

    echo
    echo "Application exited with code: $exit_code"

    return "$exit_code"
}

deploy_application() {
    echo
    echo "=============================================="
    echo "        STUDENT ATTENDANCE DEPLOYMENT"
    echo "=============================================="

    echo
    echo "Running pre-flight checks..."

    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is not installed."
        return 1
    fi

    echo "✓ python3 is installed."

    if ! command -v zip >/dev/null 2>&1; then
        echo "ERROR: zip is not installed."
        echo "Please install zip before deploying."
        return 1
    fi

    echo "✓ zip is installed."

    if ! check_templates; then
        return 1
    fi

    echo
    read -r -p "Enter project name: " input_name

    if [ -z "$input_name" ]; then
        echo "ERROR: Project name cannot be empty."
        return 1
    fi

    if [[ ! "$input_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "ERROR: Use only letters, numbers, hyphens, and underscores."
        return 1
    fi

    PROJECT_DIR="$SCRIPT_DIR/attendance_tracker_${input_name}"

    if [ -d "$PROJECT_DIR" ]; then
        echo
        echo "Project already exists:"
        echo "$PROJECT_DIR"

        read -r -p "Do you want to overwrite it? (y/n): " overwrite

        case "$overwrite" in
            y|Y)
                rm -rf "$PROJECT_DIR"
                ;;
            *)
                echo "Deployment cancelled."
                return 1
                ;;
        esac
    fi

    echo
    echo "Starting deployment..."
    echo "Project: $PROJECT_DIR"

    trap handle_deploy_interrupt SIGINT SIGTSTP

    mkdir -p \
        "$PROJECT_DIR/Helpers" \
        "$PROJECT_DIR/reports" \
        "$PROJECT_DIR/archives/attendance" \
        "$PROJECT_DIR/archives/absent"

    cp "$TEMPLATES_DIR/attendance_checker.py" \
       "$PROJECT_DIR/attendance_checker.py"

    cp "$TEMPLATES_DIR/config.json" \
       "$PROJECT_DIR/Helpers/config.json"

    echo
    echo "Choose roster option:"
    echo "A. Use students from template roster"
    echo "B. Generate a fresh sample roster"

    read -r -p "Choose A or B: " roster_choice

    case "$roster_choice" in
        A|a)
            read -r -p "How many students should be included? (1-10): " student_count

            if ! [[ "$student_count" =~ ^[0-9]+$ ]]; then
                echo "ERROR: Enter a number."
                trap - SIGINT SIGTSTP
                return 1
            fi

            if [ "$student_count" -lt 1 ] || [ "$student_count" -gt 10 ]; then
                echo "ERROR: Student count must be between 1 and 10."
                trap - SIGINT SIGTSTP
                return 1
            fi

            head -n "$((student_count + 1))" \
                "$TEMPLATES_DIR/assets.csv" \
                > "$PROJECT_DIR/Helpers/assets.csv"

            sed -i 's/"total_sessions": [0-9][0-9]*/"total_sessions": 5/' \
                "$PROJECT_DIR/Helpers/config.json"

            echo "✓ Template roster copied."
            echo "✓ total_sessions set to 5."
            ;;

        B|b)
            cat > "$PROJECT_DIR/Helpers/assets.csv" <<EOF
Email,Names,Attendance Count,Absence Count
alicia@example.com,Alicia Johnson,0,0
bob@example.com,Bob Smith,0,0
caroline@example.com,Caroline Williams,0,0
david@example.com,David Brown,0,0
emily@example.com,Emily Davis,0,0
frankline@example.com,Frankline Wilson,0,0
grace@example.com,Grace Moore,0,0
henry@example.com,Henry Taylor,0,0
irene@example.com,Irene Anderson,0,0
jack@example.com,Jack Thomas,0,0
EOF

            sed -i 's/"total_sessions": [0-9][0-9]*/"total_sessions": 1/' \
                "$PROJECT_DIR/Helpers/config.json"

            echo "✓ Fresh roster generated."
            echo "✓ total_sessions set to 1."
            ;;

        *)
            echo "ERROR: Invalid roster option."
            trap - SIGINT SIGTSTP
            return 1
            ;;
    esac

    chmod +x "$PROJECT_DIR/attendance_checker.py"
    chmod 600 "$PROJECT_DIR/Helpers/config.json"

    echo
    read -r -p "Do you want to update the thresholds? (y/n): " update_thresholds

    case "$update_thresholds" in
        y|Y)
            read -r -p "Warning threshold [75]: " warning
            read -r -p "Failure threshold [50]: " failure

            warning="${warning:-75}"
            failure="${failure:-50}"

            if ! [[ "$warning" =~ ^[0-9]+$ ]] ||
               ! [[ "$failure" =~ ^[0-9]+$ ]]; then
                echo "ERROR: Thresholds must be numbers."
                trap - SIGINT SIGTSTP
                return 1
            fi

            if [ "$warning" -gt 100 ] ||
               [ "$failure" -lt 0 ] ||
               [ "$failure" -ge "$warning" ]; then
                echo "ERROR: Need 0 <= failure < warning <= 100."
                trap - SIGINT SIGTSTP
                return 1
            fi

            sed -i "s/\"warning\": [0-9][0-9]*/\"warning\": $warning/" \
                "$PROJECT_DIR/Helpers/config.json"

            sed -i "s/\"failure\": [0-9][0-9]*/\"failure\": $failure/" \
                "$PROJECT_DIR/Helpers/config.json"

            echo "✓ Thresholds updated."
            ;;

        *)
            echo "Using existing thresholds."
            ;;
    esac

    trap - SIGINT SIGTSTP

    echo
    echo "Checking deployed structure..."

    if [ ! -f "$PROJECT_DIR/attendance_checker.py" ]; then
        echo "ERROR: attendance_checker.py missing."
        return 1
    fi

    if [ ! -f "$PROJECT_DIR/Helpers/assets.csv" ]; then
        echo "ERROR: assets.csv missing."
        return 1
    fi

    if [ ! -f "$PROJECT_DIR/Helpers/config.json" ]; then
        echo "ERROR: config.json missing."
        return 1
    fi

    if [ ! -d "$PROJECT_DIR/reports" ]; then
        echo "ERROR: reports directory missing."
        return 1
    fi

    if [ ! -d "$PROJECT_DIR/archives/attendance" ]; then
        echo "ERROR: attendance archive directory missing."
        return 1
    fi

    if [ ! -d "$PROJECT_DIR/archives/absent" ]; then
        echo "ERROR: absent archive directory missing."
        return 1
    fi

    echo "✓ Deployment structure verified."

    echo
    echo "Deployment completed successfully."

    echo
    echo "Now running the application as required by the assignment..."

    run_application "$PROJECT_DIR"
}

archive_logs() {
    local project_dir="$1"

    if [ ! -d "$project_dir" ]; then
        echo "ERROR: Project directory does not exist."
        return 1
    fi

    mkdir -p \
        "$project_dir/archives/attendance" \
        "$project_dir/archives/absent"

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"

    local attendance_log="$project_dir/reports/attendance.log"
    local absent_log="$project_dir/reports/absent.log"

    if [ -f "$attendance_log" ]; then
        local attendance_archive
        attendance_archive="$project_dir/archives/attendance/attendance_${timestamp}.log"

        cp "$attendance_log" "$attendance_archive"

        echo "✓ Attendance log archived:"
        echo "$attendance_archive"
    else
        echo "INFO: reports/attendance.log does not exist."
    fi

    if [ -f "$absent_log" ]; then
        local absent_archive
        absent_archive="$project_dir/archives/absent/absent_${timestamp}.log"

        cp "$absent_log" "$absent_archive"

        echo "✓ Absent log archived:"
        echo "$absent_archive"
    else
        echo "INFO: reports/absent.log does not exist."
    fi

    echo
    echo "Log archiving completed."
}

get_project_directory() {
    local input_name

    read -r -p "Enter deployed project name: " input_name

    if [ -z "$input_name" ]; then
        echo "ERROR: Project name cannot be empty." >&2
        return 1
    fi

    if [[ ! "$input_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "ERROR: Invalid project name." >&2
        return 1
    fi

    PROJECT_DIR="$SCRIPT_DIR/attendance_tracker_${input_name}"

    if [ ! -d "$PROJECT_DIR" ]; then
        echo "ERROR: Project does not exist: $PROJECT_DIR" >&2
        return 1
    fi
}

while true; do
    echo
    echo "=============================================="
    echo "       STUDENT ATTENDANCE DEPLOY AGENT"
    echo "=============================================="
    echo "1. Deploy application"
    echo "2. Run application"
    echo "3. Archive logs"
    echo "4. Exit"
    echo "=============================================="

    read -r -p "Choose an option: " choice

    case "$choice" in
        1)
            deploy_application
            ;;

        2)
            if get_project_directory; then
                run_application "$PROJECT_DIR"
            fi
            ;;

        3)
            if get_project_directory; then
                archive_logs "$PROJECT_DIR"
            fi
            ;;

        4)
            echo "Goodbye."
            exit 0
            ;;

        *)
            echo "Invalid option. Please choose 1, 2, 3, or 4."
            ;;
    esac
done
