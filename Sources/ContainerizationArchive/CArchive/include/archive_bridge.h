//

#pragma once

#include "archive.h"

void archive_set_error_wrapper(struct archive *a, int error_number, const char *error_string);
