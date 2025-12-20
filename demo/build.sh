# Download the code
git lfs --version
git clone https://github.com/synaptics-torq/torq-compiler.git
cd torq-compiler
scripts/checkout_submodules.sh   
# Install required system packages
# https://pypi.org/project/tensorflow/2.18.1/#files
# pip install tensorflow==2.18.1
scripts/install_dependencies.sh
# Build compiler and runtime for host
scripts/configure_python.sh ../venv ../iree-build
source ../venv/bin/activate   
ccache --max-size=20G
scripts/configure_build.sh ../iree-build
cmake --build ../iree-build/ --target torq
# Build runtime for target
scripts/configure_soc_build.sh ../iree-build-soc ../iree-build
cmake --build ../iree-build-soc/ --target iree-run-module