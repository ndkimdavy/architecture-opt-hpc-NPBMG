#!/bin/bash

set -e
set -o pipefail

# ==============================================================
# SETUP COMPILER (NPB-MG)
# ==============================================================
CLASS="C"
CLEAN_ENABLED=1
FLAGS="-O3 -march=native"
COMPILERS=("gfortran" "g++" "clang++" "aocc")

# ==============================================================
# SETUP PATHS
# ==============================================================
WORK_DIR=$(pwd)
BUILD_DIR="${WORK_DIR}/build"

# Paths structure: ("path_to_MG_folder" "file_extension")
OFFICIAL_MPI_DIR=("${WORK_DIR}/NPBx/OFFICIAL-NASA/NPB3.4-MPI/MG" "f90")
OFFICIAL_OMP_DIR=("${WORK_DIR}/NPBx/OFFICIAL-NASA/NPB3.4-OMP/MG" "f90")
NOOFFICIAL_OMP_DIR=("${WORK_DIR}/NPBx/NPB-CPP/NPB-OMP/MG" "cpp")

mkdir -p "$BUILD_DIR"

# ==============================================================
# BUILD FUNCTION
# ==============================================================
build() {
    local args=("$@")
    local path="${args[0]}"
    local ext="${args[1]}"
    local compiler="${args[2]}"

    # --- AOCC COMPILER STRATEGY ---
    if [[ "$compiler" == "aocc" ]]; then
        echo "Spack loading aocc compiler..."
        spack load aocc || { echo "Failed spack load aocc compiler"; exit 1; }
        compiler="clang++"
        echo "Spack loaded aocc compiler successfully"
    fi

    echo "Compiling: $path with $compiler"
    cd "$path"

    # Optional cleaning
    [[ "$CLEAN_ENABLED" == "1" ]] && make clean

    # ==============================================================
    # CONFIG make.def (Preparation)
    # ==============================================================
    local config_path="${path}/../config"
    local make_def="${config_path}/make.def"

    # OFFICIAL-NASA: Always restore from clean template
    if [[ "$path" == *"OFFICIAL-NASA"* ]]; then
        cp "${config_path}/make.def.template" "$make_def"
    fi

    # NPB-CPP: Create backup once, then restore from it
    if [[ "$path" == *"NPB-CPP"* ]]; then
        [[ ! -f "$make_def.bak" ]] && cp "$make_def" "$make_def.bak"
        cp "$make_def.bak" "$make_def"
    fi

    # ==============================================================
    # EDIT make.def (Surgery with sed)
    # ==============================================================
    
    # Fortran Case
    if [[ "$ext" == "f90" ]]; then
        local fc="$compiler"
        [[ "$path" == *"MPI"* ]] && fc="mpif90"
        
        sed -i "s|^FC[[:space:]]*=.*|FC = $fc|" "$make_def"
        sed -i "s|^FLINK[[:space:]]*=.*|FLINK = \$(FC)|" "$make_def"
        
        # Inject -fopenmp only for OMP directories
        if [[ "$path" == *"OMP"* ]]; then
            sed -i "s|^FFLAGS[[:space:]]*=.*|FFLAGS = $FLAGS -fopenmp|" "$make_def"
        else
            sed -i "s|^FFLAGS[[:space:]]*=.*|FFLAGS = $FLAGS|" "$make_def"
        fi
        sed -i "s|^WTIME[[:space:]]*=.*|WTIME = wtime.c|" "$make_def"
    fi

    # C++ Case
    if [[ "$ext" == "cpp" ]]; then
        sed -i "s|^CC[[:space:]]*=.*|CC = $compiler|" "$make_def"
        sed -i "s|^CLINK[[:space:]]*=.*|CLINK = \$(CC)|" "$make_def"
        # CPP version is OpenMP by default in this structure
        sed -i "s|^CFLAGS[[:space:]]*=.*|CFLAGS = $FLAGS -fopenmp|" "$make_def"
        sed -i "s|^WTIME[[:space:]]*=.*|WTIME = wtime.cpp|" "$make_def"
    fi

    # Common path for all binaries
    sed -i "s|^BINDIR[[:space:]]*=.*|BINDIR = ../bin|" "$make_def"

    # ==============================================================
    # COMPILATION
    # ==============================================================
    make mg CLASS="$CLASS"

    # Move and rename binary to centralized build directory
    local out_name="mg_${ext}_${args[2]}"
    [[ -f "../bin/mg.$CLASS" ]] && mv "../bin/mg.$CLASS" "$BUILD_DIR/$out_name"
    [[ -f "../bin/mg.$CLASS.x" ]] && mv "../bin/mg.$CLASS.x" "$BUILD_DIR/$out_name"

    # Cleanup environment for next iteration
    [[ "${args[2]}" == "aocc" ]] && spack unload aocc || true
    cd "$WORK_DIR"
}

# ==============================================================
# MAIN LOOP
# ==============================================================
for comp in "${COMPILERS[@]}"; do
    if [[ "$comp" == "gfortran" ]]; then
        # Reference builds (Official)
        build "${OFFICIAL_MPI_DIR[@]}" "$comp"
        build "${OFFICIAL_OMP_DIR[@]}" "$comp"
    else
        # Alternative compilers on CPP version
        build "${NOOFFICIAL_OMP_DIR[@]}" "$comp"
    fi
done

echo "Compilation finished. Binaries in $BUILD_DIR"