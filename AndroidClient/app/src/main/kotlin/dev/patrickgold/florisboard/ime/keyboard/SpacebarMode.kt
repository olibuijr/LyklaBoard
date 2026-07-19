/*
 * Copyright (C) 2025 The FlorisBoard Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package dev.patrickgold.florisboard.ime.keyboard

/** The three behaviors available for committing text with the space key. */
enum class SpacebarMode {
    /** Commit the current word's autocorrect candidate, then insert a space. */
    completeCurrentWord,

    /** Commit the top word prediction, then insert a space. */
    alwaysInsertPrediction,

    /** Insert a literal space without committing a candidate. */
    alwaysInsertSpace,
}
