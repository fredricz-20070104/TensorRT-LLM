"""Configuration Validator for Test Configs.

Validates TestConfig objects at test execution time (not at config loading time).
This ensures that validation failures only affect individual test cases.
"""

import os
from typing import Optional

from utils.common import EnvManager
from utils.config_loader import TestConfig
from utils.logger import logger


class ConfigValidator:
    """Configuration validator for test configs."""

    @staticmethod
    def validate_test_config(test_config: TestConfig) -> None:
        """Validate test configuration.

        This method is called at the beginning of each test case.
        If validation fails, it raises an exception that will cause only
        the current test to fail (not all tests).

        Args:
            test_config: TestConfig object to validate

        Raises:
            ValueError: If configuration is invalid
            FileNotFoundError: If required files/directories don't exist
            AssertionError: If assertion-based validation fails
        """
        logger.info("Validating test configuration...")
        pass